// Services/RouteContextBuilder.swift
// Builds per-step contexts for scoring and overlay paint.

import Foundation
import MapKit

// MARK: - Models

/// Per-step data used by the scorer and painter.
/// Keep this small and value-semantic; it's created per route request.
public struct StepContext: Sendable {
    public let index: Int
    public let polyline: MKPolyline
    public let distanceMeters: CLLocationDistance
    public let expectedTravelTime: TimeInterval
    public let avgGradePercent: Double
    public let maxUphillPercent: Double
    public let maxDownhillPercent: Double
    public let isPredominantlyDownhill: Bool
    public let bearingDegrees: Double
    public let instruction: String?
    public let surfaceHint: SurfaceType?          // optional, from local segments if available
    public let roughnessHintRMS: Double?          // optional, future: from aggregated samples

    public init(
        index: Int,
        polyline: MKPolyline,
        distanceMeters: CLLocationDistance,
        expectedTravelTime: TimeInterval,
        avgGradePercent: Double,
        maxUphillPercent: Double,
        maxDownhillPercent: Double,
        isPredominantlyDownhill: Bool,
        bearingDegrees: Double,
        instruction: String?,
        surfaceHint: SurfaceType? = nil,
        roughnessHintRMS: Double? = nil
    ) {
        self.index = index
        self.polyline = polyline
        self.distanceMeters = distanceMeters
        self.expectedTravelTime = expectedTravelTime
        self.avgGradePercent = avgGradePercent
        self.maxUphillPercent = maxUphillPercent
        self.maxDownhillPercent = maxDownhillPercent
        self.isPredominantlyDownhill = isPredominantlyDownhill
        self.bearingDegrees = bearingDegrees
        self.instruction = instruction
        self.surfaceHint = surfaceHint
        self.roughnessHintRMS = roughnessHintRMS
    }
}

// MARK: - Builder

@MainActor
public final class RouteContextBuilder: RouteContextBuilding {
    private let attributes: any StepAttributesProvider
    private let segments: SegmentStoring

    public init(attributes: any StepAttributesProvider, segments: SegmentStoring) {
        self.attributes = attributes
        self.segments = segments
    }

    /// Turn an MKRoute + GradeSummary into per-step contexts.
    /// Current GradeSummary is route-level; we propagate those aggregates to steps
    /// and compute step-local metrics (bearing, ETA, distance, instruction).
    public func context(for route: MKRoute, gradeSummary: GradeSummary) async -> [StepContext] {
        guard !route.steps.isEmpty else { return [] }

        // Basic per-route grade aggregates distributed across steps.
        // When GradeSummary gains per-sample bins, we’ll replace this with real per-step sampling.
        let routeAvg = gradeSummary.avgGradePercent
        let routeMaxUp = gradeSummary.maxUphillPercent
        let routeMaxDown = gradeSummary.maxDownhillPercent

        var output: [StepContext] = []
        output.reserveCapacity(route.steps.count)

        let stepTags = await attributes.tags(for: route.steps)

        for (idx, step) in route.steps.enumerated() {
            let poly = step.polyline
            let distance = step.distance > 0 ? step.distance : poly.distanceMetersFallback()
            let eta = step.expectedTravelTime > 0 ? step.expectedTravelTime : Self.estimateETA(distance)

            let (bearing, isDown) = Self.primaryBearingAndDownhillGuess(for: poly, avgGradePercent: routeAvg)

            let tags = idx < stepTags.count ? stepTags[idx] : .neutral
            let instruction = Self.makeInstruction(for: step, tags: tags)

            // Surface/roughness hints: placeholder.
            // Future: query `segments.segments(intersecting:)` and aggregate any surface enums.
            let surfaceHint: SurfaceType? = nil
            let roughnessHint: Double? = nil

            let ctx = StepContext(
                index: idx,
                polyline: poly,
                distanceMeters: distance,
                expectedTravelTime: eta,
                avgGradePercent: routeAvg,
                maxUphillPercent: routeMaxUp,
                maxDownhillPercent: routeMaxDown,
                isPredominantlyDownhill: isDown,
                bearingDegrees: bearing,
                instruction: instruction,
                surfaceHint: surfaceHint,
                roughnessHintRMS: roughnessHint
            )
            output.append(ctx)
        }

        return output
    }
}

// MARK: - Utilities

private extension RouteContextBuilder {
    static func makeInstruction(for step: MKRoute.Step, tags: StepTags) -> String? {
        let base = step.instructions.isEmpty ? nil : step.instructions

        var hints: [String] = []
        if tags.hasProtectedLane {
            hints.append("Protected lane")
        } else if tags.hasPaintedLane {
            hints.append("Painted lane")
        }
        if tags.surfaceRough {
            hints.append("Rough surface")
        }
        if tags.hazardCount > 0 {
            hints.append("Hazard ×\(tags.hazardCount)")
        }
        if let surface = tags.surface, !surface.isEmpty {
            hints.append(surface.capitalized)
        }

        guard !hints.isEmpty else { return base }
        let summary = hints.joined(separator: ", ")
        if let base { return "\(base) – \(summary)" }
        return summary
    }

    static func estimateETA(_ distanceMeters: CLLocationDistance) -> TimeInterval {
        // Fallback walking-ish pace (m/s). We’ll replace with mode-aware speed profiles later.
        let mps = 1.4
        return distanceMeters / mps
    }

    static func primaryBearingAndDownhillGuess(for polyline: MKPolyline, avgGradePercent: Double) -> (bearing: Double, downhill: Bool) {
        let coords = polyline.coordinates()
        guard coords.count >= 2 else { return (0, avgGradePercent < 0) }
        let start = coords.first!
        let end = coords.last!
        let bearing = headingDegrees(from: start, to: end)
        // Directional guess: negative avg grade → predominantly downhill
        return (bearing, avgGradePercent < -0.5)
    }
}

private func headingDegrees(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
    let φ1 = from.latitude * .pi / 180
    let φ2 = to.latitude * .pi / 180
    let λ1 = from.longitude * .pi / 180
    let λ2 = to.longitude * .pi / 180
    let y = sin(λ2 - λ1) * cos(φ2)
    let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(λ2 - λ1)
    let θ = atan2(y, x) * 180 / .pi
    let deg = fmod(θ + 360, 360)
    return deg.isNaN ? 0 : deg
}

private extension MKPolyline {
    func coordinates() -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }

    /// In case step.distance is 0 (rare but happens), compute from geometry.
    func distanceMetersFallback() -> CLLocationDistance {
        let pts = coordinates()
        guard pts.count > 1 else { return 0 }
        var d: CLLocationDistance = 0
        for i in 0..<(pts.count - 1) {
            let a = MKMapPoint(pts[i])
            let b = MKMapPoint(pts[i + 1])
            d += MKMetersBetweenMapPoints(a, b)
        }
        return d
    }
}


