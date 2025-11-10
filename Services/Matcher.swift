// Services/Matcher.swift
// Stateless map-matcher for aligning live samples to an MKRoute.
// Fast, allocation-light, and friendly to background threads.

import Foundation
import CoreLocation
import MapKit

// Result returned by Matcher.nearestMatch(...)
public struct MatchResult {
    public let stepIndex: Int
    public let snapped: CLLocationCoordinate2D
    public let distanceMeters: CLLocationDistance
    public let bearingDegrees: Double
    public let progressInStep: Double   // 0.0 = start, 1.0 = end
    public let confidence: Double       // 0.0–1.0, higher = better fit
}

/// Default implementation of RouteMatching.
/// No global state; safe to construct per-use or reuse across calls.
public final class Matcher: RouteMatching {

    public init() {}

    // MARK: - RouteMatching

    // Fast lookup of nearest step index by delegating to the full matcher.
    public func nearestStepIndex(on route: MKRoute, to sample: MatchSample) -> Int? {
        nearestMatch(on: route, to: sample)?.stepIndex
    }

    // Core routine: project the sample onto every step polyline and choose the best fit.
    public func nearestMatch(on route: MKRoute, to sample: MatchSample) -> MatchResult? {
        // Quick reject if route is empty
        guard !route.steps.isEmpty else { return nil }

        // Heuristic search radius; samples further than this are treated as low-confidence.
        let maxSnapRadius: CLLocationDistance = 50 // meters

        let targetPoint = MKMapPoint(sample.coordinate)
        var best: (idx: Int, snapped: MKMapPoint, dist: Double, t: Double, heading: Double, stepLen: Double)?

        for (stepIndex, step) in route.steps.enumerated() {
            let poly = step.polyline
            let count = poly.pointCount
            guard count >= 2 else { continue }

            // Iterate edges (A->B) and compute closest projection
            poly.withUnsafeMapPoints { points in
                var localBest: (snapped: MKMapPoint, dist: Double, t: Double, heading: Double, stepLen: Double)?
                for i in 0..<(count - 1) {
                    let a = points[i], b = points[i + 1]
                    let seg = segmentProjection(p: targetPoint, a: a, b: b)
                    let dist = MKMetersBetweenMapPoints(targetPoint, seg.clamped)
                    if localBest == nil || dist < localBest!.dist {
                        let heading = headingDegrees(from: a.coordinate, to: b.coordinate)
                        let stepLen = MKMetersBetweenMapPoints(a, b)
                        localBest = (seg.clamped, dist, seg.tClampedAlongStep, heading, stepLen)
                    }
                }
                if let lb = localBest {
                    if best == nil || lb.dist < best!.dist {
                        best = (stepIndex, lb.snapped, lb.dist, lb.t, lb.heading, lb.stepLen)
                    }
                }
            }
        }

        guard let b = best else { return nil }

        // Compute confidence: distance + directional agreement (if we can infer a heading from recent movement, we’d use it; for now, distance-only).
        // Distance component: 1.0 within 5m, linearly down to 0.0 at maxSnapRadius.
        let distScore = max(0, min(1, 1 - (b.dist / maxSnapRadius)))
        // Optional: incorporate roughness in future; for now, confidence = distance score.
        let confidence = distScore

        let progress = max(0, min(1, b.t)) // clamp just in case

        return MatchResult(
            stepIndex: b.idx,
            snapped: b.snapped.coordinate,
            distanceMeters: b.dist,
            bearingDegrees: b.heading,
            progressInStep: progress,
            confidence: confidence
        )
    }
}

// MARK: - Geometry helpers

private func segmentProjection(p: MKMapPoint, a: MKMapPoint, b: MKMapPoint)
-> (tRaw: Double, tClampedAlongStep: Double, clamped: MKMapPoint) {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let denom = dx*dx + dy*dy
    if denom <= 0 {
        return (0, 0, a)
    }
    let t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / denom
    let tClamped = min(1.0, max(0.0, t))
    let x = a.x + tClamped * dx
    let y = a.y + tClamped * dy
    return (t, tClamped, MKMapPoint(x: x, y: y))
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

// MARK: - Polyline access

private extension MKPolyline {
    func withUnsafeMapPoints(_ body: (_ pts: UnsafeBufferPointer<MKMapPoint>) -> Void) {
        var buf = [MKMapPoint](repeating: .init(), count: pointCount)
        getPoints(&buf, range: NSRange(location: 0, length: pointCount))
        buf.withUnsafeBufferPointer { body($0) }
    }
}
