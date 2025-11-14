// Services/OfflineRouteStore.swift
// Persists scored route options to disk for offline planning.
// Thread-safe (actor), battery-light JSON, TTL-aware with a tiny LRU index.
// Backed by CacheManager.shared but decoupled behind a minimal API.

import Foundation
import CoreLocation
import MapKit
import OSLog

public actor OfflineRouteStore {

    // MARK: - Types

    public struct RequestKey: Hashable, Sendable {
        public let source: CLLocationCoordinate2D
        public let destination: CLLocationCoordinate2D
        public let mode: RideMode

        public init(source: CLLocationCoordinate2D, destination: CLLocationCoordinate2D, mode: RideMode) {
            self.source = source
            self.destination = destination
            self.mode = mode
        }

        /// Stable cache key (quantized coords to keep keys tidy; includes mode).
        var cacheKey: String {
            let src = String(format: "%.5f,%.5f", source.latitude, source.longitude)
            let dst = String(format: "%.5f,%.5f", destination.latitude, destination.longitude)
            return "route-\(src)-\(dst)-\(mode.rawValue)"
        }
    }

    public struct Snapshot: Codable, Sendable, Identifiable, Equatable {
        public struct Coordinate: Codable, Sendable, Equatable {
            public let latitude: Double
            public let longitude: Double

            public init(latitude: Double, longitude: Double) {
                self.latitude = latitude
                self.longitude = longitude
            }

            public init(coordinate: CLLocationCoordinate2D) {
                self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
            }

            public var clCoordinate: CLLocationCoordinate2D {
                CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            }
        }

        // Identity
        public let id: UUID

        // Route candidate metadata (labels, scores, route stats)
        public let candidateID: String
        public let title: String
        public let detail: String
        public let score: Double
        public let scoreLabel: String
        public let roughnessEstimate: Double
        public let distance: Double
        public let travelTime: Double
        public let metadata: RouteService.RouteCandidateMetadata

        // Geometry (polyline as coordinates)
        public let polyline: [Coordinate]

        // Bookkeeping
        public let cachedAt: Date
        public let schemaVersion: Int

        public init(id: UUID,
                    candidateID: String,
                    title: String,
                    detail: String,
                    score: Double,
                    scoreLabel: String,
                    roughnessEstimate: Double,
                    distance: Double,
                    travelTime: Double,
                    metadata: RouteService.RouteCandidateMetadata,
                    polyline: [Coordinate],
                    cachedAt: Date = Date(),
                    schemaVersion: Int = OfflineRouteStore.schemaVersion) {
            self.id = id
            self.candidateID = candidateID
            self.title = title
            self.detail = detail
            self.score = score
            self.scoreLabel = scoreLabel
            self.roughnessEstimate = roughnessEstimate
            self.distance = distance
            self.travelTime = travelTime
            self.metadata = metadata
            self.polyline = polyline
            self.cachedAt = cachedAt
            self.schemaVersion = schemaVersion
        }

        public func makePolyline() -> MKPolyline {
            let coords = polyline.map { $0.clCoordinate }
            return MKPolyline(coordinates: coords, count: coords.count)
        }
    }

    // MARK: - Config

    public struct Config: Sendable, Equatable {
        /// Maximum number of request-keys we keep in the index (LRU trimmed).
        public var maxEntries: Int = 64
        /// Default time-to-live for a cached entry (seconds).
        public var defaultTTL: TimeInterval = 7 * 24 * 3600  // 7 days
        /// Maximum number of snapshots per key we persist (defensive).
        public var maxSnapshotsPerKey: Int = 6
        /// Maximum points allowed per polyline (snapshots will be simplified if needed).
        public var maxPolylinePoints: Int = 2500
        public init() {}
    }

    // MARK: - Constants

    public static let schemaVersion: Int = 1
    private let indexKey = "offline-route-index.json"
    private let log = Logger(subsystem: "com.yourcompany.skateroute", category: "OfflineRouteStore")

    // MARK: - Index Model

    private struct IndexEntry: Codable, Sendable, Equatable {
        let key: String
        var updatedAt: Date
        var expiresAt: Date
        var sizeBytes: Int
        var count: Int
        var schemaVersion: Int
    }

    private struct IndexFile: Codable, Sendable {
        var entries: [IndexEntry]
    }

    // MARK: - State & Dependencies

    private let cfg: Config
    private let cache = CacheManager.shared
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var index: [String: IndexEntry] = [:] // key → entry

    // MARK: - Init

    public init(config: Config = .init()) {
        self.cfg = config
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        decoder = dec

        // Load index if present
        if let data = cache.data(for: indexKey),
           let file = try? decoder.decode(IndexFile.self, from: data) {
            index = Dictionary(uniqueKeysWithValues: file.entries.map { ($0.key, $0) })
        } else {
            index = [:]
        }
    }

    // MARK: - Public API

    /// Store route snapshots for a given request key (overwrites the key).
    /// Applies clamping + simplification + LRU trimming, then writes index atomically.
    public func store(_ snapshots: [Snapshot], for key: RequestKey, ttl: TimeInterval? = nil) {
        let k = key.cacheKey
        guard !snapshots.isEmpty else {
            // Clear if caller passes empty list
            remove(for: key)
            return
        }

        let sanitized = sanitize(snapshots: snapshots)
        guard let data = try? encoder.encode(sanitized) else { return }

        do {
            try cache.store(data, key: k)
        } catch {
            log.error("Failed to store offline route data for \(k, privacy: .public): \(String(describing: error), privacy: .public)")
        }

        let entry = IndexEntry(
            key: k,
            updatedAt: Date(),
            expiresAt: Date().addingTimeInterval(ttl ?? cfg.defaultTTL),
            sizeBytes: data.count,
            count: sanitized.count,
            schemaVersion: OfflineRouteStore.schemaVersion
        )
        index[k] = entry
        trimIfNeeded()
        persistIndex()
    }

    /// Load cached snapshots if available and not expired. Returns nil when absent or stale.
    public func load(for key: RequestKey) -> [Snapshot]? {
        let k = key.cacheKey
        guard let e = index[k] else { return nil }
        guard e.expiresAt > Date() else {
            // Expired: remove eagerly
            remove(for: key)
            return nil
        }
        guard let data = cache.data(for: k) else {
            index.removeValue(forKey: k)
            persistIndex()
            return nil
        }
        guard let decoded = try? decoder.decode([Snapshot].self, from: data) else {
            // Corrupt: delete
            remove(for: key)
            return nil
        }

        // Touch LRU
        var updated = e
        updated.updatedAt = Date()
        index[k] = updated
        persistIndex()
        return decoded
    }

    /// Remove a specific cached key.
    public func remove(for key: RequestKey) {
        let k = key.cacheKey
        _ = cache.remove(key: k)
        index.removeValue(forKey: k)
        persistIndex()
    }

    /// Remove all cached routes.
    public func purgeAll() {
        for k in index.keys { _ = cache.remove(key: k) }
        index.removeAll()
        persistIndex()
    }

    /// Remove any entries past TTL or with missing payloads.
    public func purgeExpired() {
        var toDelete: [String] = []
        let now = Date()
        for (k, e) in index {
            if e.expiresAt <= now || cache.data(for: k) == nil {
                toDelete.append(k)
            }
        }
        for k in toDelete { _ = cache.remove(key: k); index.removeValue(forKey: k) }
        persistIndex()
    }

    /// Quick introspection for settings/diagnostics UI.
    public func stats() -> (count: Int, totalBytes: Int, keys: [String]) {
        let entries = Array(index.values)
        let total = entries.reduce(0) { $0 + $1.sizeBytes }
        return (entries.count, total, entries.sorted { $0.updatedAt > $1.updatedAt }.map { $0.key })
    }

    // MARK: - Private (maintenance)

    private func sanitize(snapshots: [Snapshot]) -> [Snapshot] {
        // Clamp snapshot count
        var pruned = Array(snapshots.prefix(cfg.maxSnapshotsPerKey))

        // Ensure schema + clamp polyline length defensively
        pruned = pruned.map { s in
            if s.schemaVersion == OfflineRouteStore.schemaVersion,
               s.polyline.count <= cfg.maxPolylinePoints {
                return s
            }
            let pts = simplifyPolyline(s.polyline, maxPoints: cfg.maxPolylinePoints)
            return Snapshot(
                id: s.id,
                candidateID: s.candidateID,
                title: s.title,
                detail: s.detail,
                score: s.score,
                scoreLabel: s.scoreLabel,
                roughnessEstimate: s.roughnessEstimate,
                distance: s.distance,
                travelTime: s.travelTime,
                metadata: s.metadata,
                polyline: pts,
                cachedAt: s.cachedAt,
                schemaVersion: OfflineRouteStore.schemaVersion
            )
        }
        return pruned
    }

    /// Very light polyline simplifier by uniform subsampling. Cheap and safe for short city routes.
    private func simplifyPolyline(_ coords: [Snapshot.Coordinate], maxPoints: Int) -> [Snapshot.Coordinate] {
        guard coords.count > maxPoints, maxPoints > 1 else { return coords }
        let step = Double(coords.count - 1) / Double(maxPoints - 1)
        var out: [Snapshot.Coordinate] = []
        out.reserveCapacity(maxPoints)
        var i = 0.0
        while Int(i.rounded()) < coords.count && out.count < maxPoints {
            out.append(coords[Int(i.rounded())])
            i += step
        }
        if out.last != coords.last { out.append(coords.last!) }
        return out
    }

    private func trimIfNeeded() {
        // LRU trim by updatedAt when exceeding capacity.
        guard index.count > cfg.maxEntries else { return }
        let sorted = index.values.sorted { $0.updatedAt < $1.updatedAt }
        let overflow = sorted.prefix(index.count - cfg.maxEntries)
        for e in overflow {
            _ = cache.remove(key: e.key)
            index.removeValue(forKey: e.key)
        }
    }

    private func persistIndex() {
        let entries = Array(index.values)
        let file = IndexFile(entries: entries)
        if let data = try? encoder.encode(file) {
            try? cache.store(data, key: indexKey)
        }
    }
}

// MARK: - Convenience (bridge for existing call sites)

extension OfflineRouteStore {
    /// Back-compat sync-shaped wrappers (dispatch onto the actor).
    public nonisolated func storeSync(_ snapshots: [Snapshot], for key: RequestKey, ttl: TimeInterval? = nil) {
        Task { await self.store(snapshots, for: key, ttl: ttl) }
    }

    public nonisolated func loadSync(for key: RequestKey, completion: @escaping ([Snapshot]?) -> Void) {
        Task { completion(await self.load(for: key)) }
    }
}

// MARK: - Debug Preview Helpers (optional)

#if DEBUG
extension OfflineRouteStore.Snapshot {
    public static func preview(id: UUID = .init(),
                               candidateID: String = "cand-1",
                               title: String = "Smooth waterfront",
                               detail: String = "Fewer crossings • Low grade",
                               score: Double = 0.92,
                               scoreLabel: String = "A",
                               roughnessEstimate: Double = 0.18,
                               distance: Double = 3200,
                               travelTime: Double = 780,
                               metadata: RouteService.RouteCandidateMetadata? = nil,
                               coords: [CLLocationCoordinate2D],
                               date: Date = Date()) -> OfflineRouteStore.Snapshot {
        let resolvedMetadata = metadata ?? RouteService.RouteCandidateMetadata(
            distanceMeters: distance,
            expectedTravelTimeSeconds: travelTime,
            gradeSummary: GradeSummary(
                totalDistanceMeters: distance,
                samples: 1,
                avgGradePercent: 0,
                maxUphillPercent: 0,
                maxDownhillPercent: 0,
                totalAscentMeters: 0,
                totalDescentMeters: 0,
                sampleDistanceMeters: distance,
                sampleGradesPercent: [],
                smoothedGradesPercent: []
            )
        )

        return .init(id: id,
                     candidateID: candidateID,
                     title: title,
                     detail: detail,
                     score: score,
                     scoreLabel: scoreLabel,
                     roughnessEstimate: roughnessEstimate,
                     distance: distance,
                     travelTime: travelTime,
                     metadata: resolvedMetadata,
                     polyline: coords.map { .init(coordinate: $0) },
                     cachedAt: date,
                     schemaVersion: OfflineRouteStore.schemaVersion)
    }
}
#endif


