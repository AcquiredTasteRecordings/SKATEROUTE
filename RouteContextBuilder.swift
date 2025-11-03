// Services/RouteContextBuilder.swift
import Foundation
import MapKit
import CoreLocation

// MARK: - Context types the scorer will consume

/// Per-step context factors the scorer can weight.
public struct StepContext: Sendable {
    public let stepIndex: Int
    public let laneBonus: Double          // +ve if protected/painted lanes
    public let turnPenalty: Double        // +ve if sharp (esp. downhill later)
    public let hazardPenalty: Double      // +ve if potholes/grates etc.
    public let tags: StepTags             // raw tag facts (debug/legend)

    public init(stepIndex: Int,
                laneBonus: Double,
                turnPenalty: Double,
                hazardPenalty: Double,
                tags: StepTags) {
        self.stepIndex = stepIndex
        self.laneBonus = laneBonus
        self.turnPenalty = turnPenalty
        self.hazardPenalty = hazardPenalty
        self.tags = tags
    }
}

/// Raw attributes extracted from OSM/municipal/community tags.
/// (We’ll fill these via a provider in the next file.)
public struct StepTags: Sendable {
    public let hasProtectedLane: Bool    // e.g. cycleway=track/protected
    public let hasPaintedLane: Bool      // cycleway=lane
    public let surfaceRough: Bool        // cobblestone/compacted/etc.
    public let hazardCount: Int          // pothole/grate/rail reports
    public let highwayClass: String?     // OSM highway=*
    public let surface: String?          // OSM surface=*
    public let lightingLevel: String?    // e.g. "good", "poor", "none"
    public let freshnessDays: Int?       // age of data in days

    public init(hasProtectedLane: Bool = false,
                hasPaintedLane: Bool = false,
                surfaceRough: Bool = false,
                hazardCount: Int = 0,
                highwayClass: String? = nil,
                surface: String? = nil,
                lightingLevel: String? = nil,
                freshnessDays: Int? = nil) {
        self.hasProtectedLane = hasProtectedLane
        self.hasPaintedLane = hasPaintedLane
        self.surfaceRough = surfaceRough
        self.hazardCount = hazardCount
        self.highwayClass = highwayClass
        self.surface = surface
        self.lightingLevel = lightingLevel
        self.freshnessDays = freshnessDays
    }
}

// MARK: - RouteContextBuilder

/// Builds `StepContext` array aligned with `route.steps`.
///
/// This class is responsible for assembling contextual information for each navigation step,
/// which can then be used by a scoring system to evaluate route quality and safety.
/// It processes step geometries and attributes such as bike lanes, surface roughness, hazards,
/// lighting conditions, and data freshness to produce weighted factors.
/// 
/// To improve performance on repeated routing queries, it maintains a lightweight cache of previously processed step tags.
/// Thread safety is ensured for cache access.
///
public final class RouteContextBuilder {
    private let attributes: StepAttributesProvider
    private var tagsCache: [Int: StepTags] = [:]
    private let cacheQueue = DispatchQueue(label: "RouteContextBuilder.tagsCacheQueue", attributes: .concurrent)

    /// Inject an attributes provider. Start with `NoopAttributesProvider()`.
    /// - Parameter attributes: The provider used to fetch raw step attributes.
    public init(attributes: StepAttributesProvider) {
        self.attributes = attributes
    }

    /// Returns a `StepContext` for every step (distance > 0) in the route.
    ///
    /// This method calculates turn penalties based on geometry,
    /// fetches and caches step tags asynchronously,
    /// and computes lane bonuses and hazard penalties incorporating lighting and freshness.
    /// 
    /// - Parameter route: The route whose steps are to be processed.
    /// - Returns: An array of `StepContext` aligned with the route's steps.
    public func context(for route: MKRoute) async -> [StepContext] {
        let steps = route.steps
        guard !steps.isEmpty else { return [] }

        // Precompute bearings for turn-angle penalty.
        let bearings: [Double?] = steps.map { firstToLastBearing(of: $0.polyline) }

        var result: [StepContext] = []
        result.reserveCapacity(steps.count)

        for i in 0..<steps.count {
            let step = steps[i]
            guard step.distance > 0 else {
                result.append(StepContext(stepIndex: i,
                                          laneBonus: 0,
                                          turnPenalty: 0,
                                          hazardPenalty: 0,
                                          tags: StepTags()))
                continue
            }

            // 1) Turn penalty from bearing delta with previous step
            let turnPen = turnPenalty(previousBearing: i > 0 ? bearings[i-1] : nil,
                                      currentBearing: bearings[i])

            // 2) Tags (bike lanes, surface, hazards)
            let tags: StepTags
            if let cachedTags = cachedTags(for: i) {
                tags = cachedTags
            } else {
                tags = await attributes.tags(for: step)
                cacheTags(tags, for: i)
            }

            // 3) Lane bonus & 4) Hazard penalty heuristics including lighting and freshness
            let lane = laneBonus(for: tags)
            let hazard = hazardPenalty(for: tags)

            let context = StepContext(stepIndex: i,
                                      laneBonus: lane,
                                      turnPenalty: turnPen,
                                      hazardPenalty: hazard,
                                      tags: tags)
            result.append(context)

            // Debug logging
            debugLog(stepIndex: i, laneBonus: lane, turnPenalty: turnPen, hazardPenalty: hazard, lightingLevel: tags.lightingLevel)
        }
        return result
    }

    /// Retrieves cached tags for a step index in a thread-safe manner.
    private func cachedTags(for stepIndex: Int) -> StepTags? {
        var tags: StepTags?
        cacheQueue.sync {
            tags = tagsCache[stepIndex]
        }
        return tags
    }

    /// Caches tags for a step index in a thread-safe manner.
    private func cacheTags(_ tags: StepTags, for stepIndex: Int) {
        cacheQueue.async(flags: .barrier) {
            self.tagsCache[stepIndex] = tags
        }
    }

    /// Logs debug information for a created StepContext.
    private func debugLog(stepIndex: Int, laneBonus: Double, turnPenalty: Double, hazardPenalty: Double, lightingLevel: String?) {
        let lighting = lightingLevel ?? "unknown"
        print("StepContext created - Step: \(stepIndex), laneBonus: \(laneBonus), turnPenalty: \(turnPenalty), hazardPenalty: \(hazardPenalty), lightingLevel: \(lighting)")
    }
}

// MARK: - Heuristics

private extension RouteContextBuilder {
    /// +ve penalty for sharp turns (geometry-only here).
    func turnPenalty(previousBearing: Double?, currentBearing: Double?) -> Double {
        guard let a = previousBearing, let b = currentBearing else { return 0 }
        let delta = smallestAngleDiffDegrees(a, b)
        // Thresholds: >70° noticeable, >110° harsh
        switch delta {
        case 0..<50:   return 0
        case 50..<70:  return 0.05
        case 70..<90:  return 0.12
        case 90..<110: return 0.20
        default:       return 0.30
        }
    }

    /// Reward protected lanes strongest, painted lanes modestly.
    ///
    /// Additionally, slightly penalize poor lighting and reward recent/fresh data.
    func laneBonus(for tags: StepTags) -> Double {
        var bonus = 0.0
        if tags.hasProtectedLane { bonus += 0.30 }
        else if tags.hasPaintedLane { bonus += 0.12 }

        // Slight penalty for poor lighting
        if let lighting = tags.lightingLevel?.lowercased(), lighting == "poor" || lighting == "none" {
            bonus -= 0.05
        }

        // Slight reward (negative penalty) for fresh data (less than 3 days)
        if let freshness = tags.freshnessDays, freshness < 3 {
            bonus -= 0.03
        }

        return bonus
    }

    /// Penalize hazards and rough surfaces.
    ///
    /// Additionally, slightly penalize poor lighting and reward recent/fresh data.
    func hazardPenalty(for tags: StepTags) -> Double {
        var p = 0.0
        if tags.surfaceRough { p += 0.15 }
        if tags.hazardCount > 0 {
            // Each reported hazard adds 0.08 up to a cap.
            p += min(0.40, Double(tags.hazardCount) * 0.08)
        }

        // Slight penalty for poor lighting
        if let lighting = tags.lightingLevel?.lowercased(), lighting == "poor" || lighting == "none" {
            p += 0.05
        }

        // Slight reward (negative penalty) for fresh data (less than 3 days)
        if let freshness = tags.freshnessDays, freshness < 3 {
            p -= 0.03
        }

        return p
    }
}

// MARK: - Geometry helpers (no external extensions required)

private extension RouteContextBuilder {
    /// Bearing (degrees) from first to last coordinate of a polyline (coarse).
    func firstToLastBearing(of polyline: MKPolyline) -> Double? {
        let count = polyline.pointCount
        guard count >= 2 else { return nil }
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        guard let a = coords.first, let b = coords.last else { return nil }
        return bearing(from: a, to: b)
    }

    func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi/180
        let lat2 = b.latitude * .pi/180
        let dLon = (b.longitude - a.longitude) * .pi/180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1)*sin(lat2) - sin(lat1)*cos(lat2)*cos(dLon)
        var brng = atan2(y, x) * 180 / .pi
        if brng < 0 { brng += 360 }
        return brng
    }

    /// Absolute smallest difference between two bearings (0...180).
    func smallestAngleDiffDegrees(_ a: Double, _ b: Double) -> Double {
        let diff = abs(a - b).truncatingRemainder(dividingBy: 360)
        return diff > 180 ? 360 - diff : diff
    }
}
