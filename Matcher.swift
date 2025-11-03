// Services/Matcher.swift
import SwiftUI
import MapKit
import CoreLocation
import Combine
import UIKit

/// Matcher is responsible for map-matching RMS vibration samples to route segments within SKATEROUTE.
/// It helps associate vibration data collected from the device with specific steps along a given route,
/// enabling analysis and visualization of roughness on the route segments.
///
/// This class improves performance by caching recent match results keyed by route identifier,
/// supports configurable tolerance for matching distance, and provides hooks for debugging and metrics tracking.
public final class Matcher {
    public init() {}

    /// Cache storing the most recent matched step index per route identifier to optimize repeated queries.
    private var recentMatches: [String: (stepIndex: Int, distance: CLLocationDistance)] = [:]

    /// Metrics tracking total matches and cumulative distance for accuracy tuning.
    private(set) var totalMatches: Int = 0
    private(set) var cumulativeDistance: CLLocationDistance = 0

    /// Optional debug overlay callback to report matched step indices for visualization in developer builds.
    /// The closure receives the route identifier and matched step index.
    public var debugOverlayCallback: ((String, Int) -> Void)?

    /// Returns the nearest step index on the route to the sample's snapped coordinate.
    ///
    /// - Parameters:
    ///   - route: The MKRoute to match against.
    ///   - sample: The vibration sample containing location and roughness RMS.
    ///   - tolerance: Optional maximum distance in meters for accepting a match. Defaults to 40.
    ///
    /// - Returns: The index of the nearest step within the tolerance, or nil if no close match found.
    public func nearestStepIndex(on route: MKRoute, to sample: MatchSample, tolerance: CLLocationDistance = 40) -> Int? {
        let routeID = route.name ?? UUID().uuidString

        // Check cache first to avoid redundant computations for close samples on the same route
        if let cached = recentMatches[routeID] {
            let cachedStepIndex = cached.stepIndex
            let cachedDistance = cached.distance
            if cachedDistance <= tolerance {
                debugOverlayCallback?(routeID, cachedStepIndex)
                return cachedStepIndex
            }
        }

        let steps = route.steps
        guard !steps.isEmpty else { return nil }

        var bestIndex = 0
        var bestDist = CLLocationDistance.greatestFiniteMagnitude
        for (i, s) in steps.enumerated() where s.distance > 0 {
            // Use the first point of the step polyline as a proxy for its segment
            let c = s.polyline.coordinates().first ?? route.polyline.coordinates().first!
            let d = sample.location.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            if d < bestDist { bestDist = d; bestIndex = i }
        }
        // Only accept close matches within tolerance to avoid noise
        guard bestDist < tolerance else { return nil }

        // Update cache and metrics
        recentMatches[routeID] = (bestIndex, bestDist)
        totalMatches += 1
        cumulativeDistance += bestDist

        debugOverlayCallback?(routeID, bestIndex)
        return bestIndex
    }
}
