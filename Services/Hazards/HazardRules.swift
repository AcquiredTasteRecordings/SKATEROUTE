// Services/Hazards/HazardRules.swift
// Opinionated rules engine for de-dupe/merge, severity bucketing, and TTL/decay.
// Pure functions, DI-friendly, testable. No UI types, no network. MapKit-free except for coordinates.

import Foundation
import CoreLocation

// MARK: - Public model shims (aligned with HazardStore)

public enum HazardKind: String, Codable, CaseIterable {
    // Keep in sync with HazardStore; optional extra kinds supported via rawValue lookup.
    case pothole, gravel, rail, crack, debris, wet, other
    // If you add "construction" in Models later, this file already supports it via rawValue mapping.
}

public enum HazardStatus: String, Codable, CaseIterable { case active, resolved, expired }

// Severity buckets drive renderer colors and alert priority.
public enum SeverityBucket: String, Codable, CaseIterable {
    case low, medium, high, critical
}

// Priority for HazardAlertService to throttle/voice emphasis.
public enum AlertPriority: String, Codable, CaseIterable {
    case low, normal, high
}

// MARK: - Rules Engine

public struct HazardRules: Sendable, Equatable {
    // Spatial merge radius per type (meters). Unknown kinds fall back to defaultRadiusMeters.
    public var mergeRadiusByKindMeters: [String: Double]
    public var defaultRadiusMeters: Double

    // TTLs per type (seconds). Unknown kinds fall back to defaultTTL.
    public var ttlByKindSeconds: [String: TimeInterval]
    public var defaultTTL: TimeInterval

    // Severity thresholds (1...5) → bucket. Inclusive upper bounds.
    public var bucketThresholds: [Int: SeverityBucket] // e.g., 1→.low, 2→.low, 3→.medium, 4→.high, 5→.critical

    // Auto-downgrade timings (seconds since last update) per bucket.
    public var downgradeAfterSeconds: [SeverityBucket: TimeInterval]

    // Verified “resolved” consensus: minimum confirmations after last update to consider auto-resolved.
    public var resolveConsensusConfirmations: Int

    // Optional clock for tests
    private let now: () -> Date

    public init(
        mergeRadiusByKindMeters: [String: Double] = [
            "wet": 18, "debris": 20, "gravel": 20, "crack": 25, "pothole": 25, "rail": 35,
            "construction": 60, "other": 25
        ],
        defaultRadiusMeters: Double = 25,
        ttlByKindSeconds: [String: TimeInterval] = [
            "wet": 1*24*3600, "debris": 2*24*3600, "gravel": 7*24*3600, "crack": 120*24*3600,
            "pothole": 60*24*3600, "rail": 365*24*3600, "construction": 30*24*3600, "other": 14*24*3600
        ],
        defaultTTL: TimeInterval = 14*24*3600,
        bucketThresholds: [Int: SeverityBucket] = [
            1: .low, 2: .low, 3: .medium, 4: .high, 5: .critical
        ],
        downgradeAfterSeconds: [SeverityBucket: TimeInterval] = [
            .critical: 14*24*3600,
            .high:     10*24*3600,
            .medium:   7*24*3600,
            .low:      3*24*3600
        ],
        resolveConsensusConfirmations: Int = 3,
        now: @escaping () -> Date = { Date() }
    ) {
        self.mergeRadiusByKindMeters = mergeRadiusByKindMeters
        self.defaultRadiusMeters = defaultRadiusMeters
        self.ttlByKindSeconds = ttlByKindSeconds
        self.defaultTTL = defaultTTL
        self.bucketThresholds = bucketThresholds
        self.downgradeAfterSeconds = downgradeAfterSeconds
        self.resolveConsensusConfirmations = resolveConsensusConfirmations
        self.now = now
    }
}

// MARK: - Public API

public extension HazardRules {

    // MARK: Spatial de-dupe / merge

    func mergeRadius(for kind: HazardKind, customRawKindIfAny: String? = nil) -> CLLocationDistance {
        let k = (customRawKindIfAny ?? kind.rawValue).lowercased()
        return mergeRadiusByKindMeters[k] ?? defaultRadiusMeters
    }

    /// Should two hazards merge? Considers kind equality (or custom raw kind match) and distance.
    func shouldMerge(kindA: String, coordA: CLLocationCoordinate2D,
                     kindB: String, coordB: CLLocationCoordinate2D) -> Bool {
        guard kindA.lowercased() == kindB.lowercased() else { return false }
        let radius = mergeRadiusByKindMeters[kindA.lowercased()] ?? defaultRadiusMeters
        return haversine(coordA, coordB) <= radius
    }

    /// Merge policy: confirmations sum, severity = max, position = weighted centroid by confirmations.
    func mergedAttributes(
        aConfirmations: Int, aSeverity: Int, aCoord: CLLocationCoordinate2D,
        bConfirmations: Int, bSeverity: Int, bCoord: CLLocationCoordinate2D
    ) -> (confirmations: Int, severity: Int, coordinate: CLLocationCoordinate2D) {
        let total = max(1, aConfirmations) + max(1, bConfirmations)
        let wa = Double(max(1, aConfirmations))
        let wb = Double(max(1, bConfirmations))
        let coord = weightedSphericalCentroid(aCoord, wa, bCoord, wb)
        return (total, max(aSeverity, bSeverity), coord)
    }

    // MARK: Severity → bucket / alert priority

    func bucket(for severity: Int) -> SeverityBucket {
        let s = max(1, min(5, severity))
        return bucketThresholds[s] ?? .medium
    }

    func alertPriority(for bucket: SeverityBucket) -> AlertPriority {
        switch bucket {
        case .critical: return .high
        case .high: return .high
        case .medium: return .normal
        case .low: return .low
        }
    }

    /// Renderer color token (kept semantic; UI maps token→Color).
    func rendererColorToken(for bucket: SeverityBucket) -> String {
        switch bucket {
        case .critical: return "hazardCritical"
        case .high:     return "hazardHigh"
        case .medium:   return "hazardMedium"
        case .low:      return "hazardLow"
        }
    }

    // MARK: TTL / decay / resolution

    func ttl(for kind: HazardKind, customRawKindIfAny: String? = nil) -> TimeInterval {
        let k = (customRawKindIfAny ?? kind.rawValue).lowercased()
        return ttlByKindSeconds[k] ?? defaultTTL
    }

    /// Returns the recommended expiresAt for a newly created/updated hazard.
    func recommendedExpiry(kind: HazardKind, updatedAt: Date, customRawKindIfAny: String? = nil) -> Date {
        updatedAt.addingTimeInterval(ttl(for: kind, customRawKindIfAny: customRawKindIfAny))
    }

    /// Given lastUpdated and bucket, compute if we should auto-downgrade the visual bucket.
    func downgradedBucketIfStale(original: SeverityBucket, lastUpdatedAt: Date) -> SeverityBucket {
        let age = now().timeIntervalSince(lastUpdatedAt)
        guard let cutoff = downgradeAfterSeconds[original], age >= cutoff else { return original }
        // Simple step-down by one level per cutoff interval elapsed.
        let steps = Int(age / cutoff)
        return stepDown(bucket: original, times: steps)
    }

    /// Deterministic next status applying TTL and verified resolve.
    /// - Parameters:
    ///   - kind/rawKind: hazard category
    ///   - status: current status
    ///   - updatedAt/expiresAt: timing
    ///   - resolveVotes: number of confirmations _after_ a "resolved" action (UI/Moderation sets this)
    public func nextStatus(kind: HazardKind,
                           rawKindOverride: String? = nil,
                           status: HazardStatus,
                           updatedAt: Date,
                           expiresAt: Date?,
                           resolveVotes: Int) -> HazardStatus {
        if resolveVotes >= resolveConsensusConfirmations { return .resolved }
        if let expiry = expiresAt, now() >= expiry { return .expired }
        // If no explicit expiry was stored, compute TTL from kind.
        let ttlEnd = updatedAt.addingTimeInterval(ttl(for: kind, customRawKindIfAny: rawKindOverride))
        return now() >= ttlEnd ? .expired : status
    }
}

// MARK: - Private helpers

private extension HazardRules {
    func stepDown(bucket: SeverityBucket, times: Int) -> SeverityBucket {
        guard times > 0 else { return bucket }
        switch bucket {
        case .critical: return stepDown(bucket: .high, times: times - 1)
        case .high:     return stepDown(bucket: .medium, times: times - 1)
        case .medium:   return stepDown(bucket: .low, times: times - 1)
        case .low:      return .low
        }
    }

    // Haversine distance (meters)
    func haversine(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let r = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let h = sin(dLat/2)*sin(dLat/2) + sin(dLon/2)*sin(dLon/2)*cos(lat1)*cos(lat2)
        return 2*r*asin(min(1, sqrt(h)))
    }

    // Weighted centroid on sphere using simple cartesian average (good enough at city scale).
    func weightedSphericalCentroid(_ a: CLLocationCoordinate2D, _ wa: Double,
                                   _ b: CLLocationCoordinate2D, _ wb: Double) -> CLLocationCoordinate2D {
        func toXYZ(_ c: CLLocationCoordinate2D, _ w: Double) -> (x: Double,y: Double,z: Double) {
            let lat = c.latitude * .pi/180, lon = c.longitude * .pi/180
            return (w * cos(lat) * cos(lon), w * cos(lat) * sin(lon), w * sin(lat))
        }
        let A = toXYZ(a, wa), B = toXYZ(b, wb)
        let x = A.x + B.x, y = A.y + B.y, z = A.z + B.z
        let lon = atan2(y, x), hyp = sqrt(x*x + y*y), lat = atan2(z, hyp)
        return .init(latitude: lat * 180 / .pi, longitude: lon * 180 / .pi)
    }
}

// MARK: - Integration helpers (used by HazardStore / Renderer / Alerts)

public extension HazardRules {
    /// Single-call decision used by HazardStore when inserting/updating a hazard.
    struct UpsertDecision {
        public let confirmations: Int
        public let severity: Int
        public let bucket: SeverityBucket
        public let alertPriority: AlertPriority
        public let coordinate: CLLocationCoordinate2D
        public let expiresAt: Date
    }

    /// Compute merged attributes + bucket + expiry for a hazard write.
    func decideUpsert(kind: HazardKind,
                      rawKindOverride: String? = nil,
                      newSeverity: Int,
                      newConfirmations: Int,
                      coordinate: CLLocationCoordinate2D,
                      existing: (severity: Int, confirmations: Int, coordinate: CLLocationCoordinate2D)?,
                      updatedAt: Date) -> UpsertDecision {
        let merged: (c: Int, s: Int, coord: CLLocationCoordinate2D) = {
            if let ex = existing {
                let m = mergedAttributes(aConfirmations: ex.confirmations, aSeverity: ex.severity, aCoord: ex.coordinate,
                                         bConfirmations: newConfirmations, bSeverity: newSeverity, bCoord: coordinate)
                return (m.confirmations, m.severity, m.coordinate)
            } else {
                return (max(1, newConfirmations), max(1, min(5, newSeverity)), coordinate)
            }
        }()

        let b0 = bucket(for: merged.s)
        let b = downgradedBucketIfStale(original: b0, lastUpdatedAt: updatedAt)
        let p = alertPriority(for: b)
        let exp = recommendedExpiry(kind: kind, updatedAt: updatedAt, customRawKindIfAny: rawKindOverride)

        return UpsertDecision(confirmations: merged.c, severity: merged.s, bucket: b, alertPriority: p, coordinate: merged.coord, expiresAt: exp)
    }
}
