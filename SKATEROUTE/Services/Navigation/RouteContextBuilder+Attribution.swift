//  Services/Navigation/RouteContextBuilder+Attribution.swift
//  SKATEROUTE
//
//  Attribution plug-in for RouteContextBuilder.
//  Computes per-step lane/hazard/legality/crossing context using AttributionService,
//  and derives a lightweight skateability score for each step + overall summary.

import Foundation
import MapKit
import CoreLocation

/// Per-step attribution derived from local tiles.
/// This is intentionally decoupled from any UI so it can be reused by overlays, nav HUD, and scoring.
public struct RouteStepAttribution: Sendable, Hashable, Identifiable {
    public let id: String                 // route + step index
    public let stepIndex: Int
    public let distance: CLLocationDistance

    public let hasBikeLane: Bool?
    public let hazardScore01: Double?
    public let legalityScore01: Double?
    public let crossingsPerKm: Double?

    /// Synthetic skateability in [0,1], combining hazard, legality, lane and crossings.
    /// Higher = better for skating.
    public let skateabilityScore01: Double

    public init(
        id: String,
        stepIndex: Int,
        distance: CLLocationDistance,
        hasBikeLane: Bool?,
        hazardScore01: Double?,
        legalityScore01: Double?,
        crossingsPerKm: Double?,
        skateabilityScore01: Double
    ) {
        self.id = id
        self.stepIndex = stepIndex
        self.distance = max(0, distance)
        self.hasBikeLane = hasBikeLane
        self.hazardScore01 = hazardScore01
        self.legalityScore01 = legalityScore01
        self.crossingsPerKm = crossingsPerKm
        self.skateabilityScore01 = max(0, min(1, skateabilityScore01))
    }
}

/// Aggregate view over an entire route, used for cards/filters/leaderboards.
public struct RouteAttributionSummary: Sendable, Hashable {
    public let averageHazard01: Double?
    public let averageLegality01: Double?
    public let laneDistanceRatio01: Double?
    public let averageCrossingsPerKm: Double?
    public let overallSkateability01: Double?
    public let datasetVersion: String

    public init(
        averageHazard01: Double?,
        averageLegality01: Double?,
        laneDistanceRatio01: Double?,
        averageCrossingsPerKm: Double?,
        overallSkateability01: Double?,
        datasetVersion: String
    ) {
        self.averageHazard01 = averageHazard01
        self.averageLegality01 = averageLegality01
        self.laneDistanceRatio01 = laneDistanceRatio01
        self.averageCrossingsPerKm = averageCrossingsPerKm
        self.overallSkateability01 = overallSkateability01
        self.datasetVersion = datasetVersion
    }
}

// MARK: - Core attribution hook for RouteContextBuilder

public extension RouteContextBuilder {

    /// Compute per-step attribution for a MapKit route using the given AttributionServiceType.
    /// - Important: This does **not** mutate RouteContextBuilder; it's purely functional.
    func buildAttribution(
        for route: MKRoute,
        attributionService: AttributionServiceType
    ) async -> [RouteStepAttribution] {
        guard !route.steps.isEmpty else { return [] }

        var result: [RouteStepAttribution] = []
        result.reserveCapacity(route.steps.count)

        let routeId = route.advisoryNotices.joined(separator: "|") // cheap-ish identifier; replace if you have a real one

        for (index, step) in route.steps.enumerated() {
            let distance = step.distance
            guard distance > 0,
                  let start = step.polyline.coordinates.first,
                  let end = step.polyline.coordinates.last
            else {
                // Zero-length or malformed step: still emit a placeholder for index stability
                let empty = RouteStepAttribution(
                    id: "\(routeId)#\(index)",
                    stepIndex: index,
                    distance: max(0, distance),
                    hasBikeLane: nil,
                    hazardScore01: nil,
                    legalityScore01: nil,
                    crossingsPerKm: nil,
                    skateabilityScore01: 0.5 // neutral
                )
                result.append(empty)
                continue
            }

            // Query attribution along the segment; the actor isolates the real work.
            let attrs = await attributionService.attributes(along: start, to: end)

            let lane = attrs?.hasBikeLane
            let hazard = clamped01(attrs?.hazardScore01)
            let legality = clamped01(attrs?.legalityScore01)
            let crossings = attrs?.crossingsPerKm

            let skateability = Self.deriveSkateability(
                hasBikeLane: lane,
                hazard01: hazard,
                legality01: legality,
                crossingsPerKm: crossings
            )

            let stepAttr = RouteStepAttribution(
                id: "\(routeId)#\(index)",
                stepIndex: index,
                distance: distance,
                hasBikeLane: lane,
                hazardScore01: hazard,
                legalityScore01: legality,
                crossingsPerKm: crossings,
                skateabilityScore01: skateability
            )
            result.append(stepAttr)
        }

        return result
    }

    /// Compute a route-level summary from per-step attribution.
    func summarizeAttribution(
        _ steps: [RouteStepAttribution],
        datasetVersion: String
    ) -> RouteAttributionSummary {
        guard !steps.isEmpty else {
            return RouteAttributionSummary(
                averageHazard01: nil,
                averageLegality01: nil,
                laneDistanceRatio01: nil,
                averageCrossingsPerKm: nil,
                overallSkateability01: nil,
                datasetVersion: datasetVersion
            )
        }

        let totalDistance = steps.reduce(0.0) { $0 + $1.distance }
        let safeDistance = max(totalDistance, 0.1)

        var hazardAccum = 0.0
        var hazardWeight = 0.0
        var legalityAccum = 0.0
        var legalityWeight = 0.0
        var laneDistance = 0.0
        var crossingsAccum = 0.0
        var crossingsWeight = 0.0
        var skateAccum = 0.0

        for step in steps {
            let w = step.distance
            if let h = step.hazardScore01 {
                hazardAccum += h * w
                hazardWeight += w
            }
            if let l = step.legalityScore01 {
                legalityAccum += l * w
                legalityWeight += w
            }
            if let hasLane = step.hasBikeLane, hasLane {
                laneDistance += w
            }
            if let c = step.crossingsPerKm {
                crossingsAccum += c * w
                crossingsWeight += w
            }
            skateAccum += step.skateabilityScore01 * w
        }

        let avgHazard = hazardWeight > 0 ? hazardAccum / hazardWeight : nil
        let avgLegality = legalityWeight > 0 ? legalityAccum / legalityWeight : nil
        let laneRatio = laneDistance > 0 ? laneDistance / safeDistance : nil
        let avgCrossings = crossingsWeight > 0 ? crossingsAccum / crossingsWeight : nil
        let overallSkate = skateAccum / safeDistance

        return RouteAttributionSummary(
            averageHazard01: avgHazard,
            averageLegality01: avgLegality,
            laneDistanceRatio01: laneRatio,
            averageCrossingsPerKm: avgCrossings,
            overallSkateability01: overallSkate,
            datasetVersion: datasetVersion
        )
    }

    // MARK: - Internal scoring model

    /// Heuristic skateability model:
    /// - Start neutral at 0.5
    /// - Subtract based on hazard
    /// - Multiply by legality
    /// - Add lane bonus
    /// - Penalize heavy crossings
    private static func deriveSkateability(
        hasBikeLane: Bool?,
        hazard01: Double?,
        legality01: Double?,
        crossingsPerKm: Double?
    ) -> Double {
        var score = 0.5

        if let h = hazard01 {
            // Hazard hits harder than legality bonuses: we don’t want to send riders into sketchy segments.
            score -= h * 0.5
        }

        if let l = legality01 {
            // Legality as a soft multiplier, not a hard clamp.
            score *= (0.5 + 0.5 * l)
        }

        if hasBikeLane == true {
            score += 0.15
        }

        if let x = crossingsPerKm {
            // Penalize busy crossings but keep it bounded.
            let clamped = min(max(x, 0), 20)
            score -= (clamped / 20.0) * 0.2
        }

        return max(0, min(1, score))
    }
}

// MARK: - Private helpers

private func clamped01(_ value: Double?) -> Double? {
    guard let v = value else { return nil }
    return max(0, min(1, v))
}

private extension MKPolyline {
    /// Convenience accessor for all coordinates in a polyline.
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: pointCount)
        guard pointCount > 0 else { return [] }
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}


