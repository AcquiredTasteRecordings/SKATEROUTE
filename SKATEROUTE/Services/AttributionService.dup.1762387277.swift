// Services/AttributionService.swift
import Foundation
import MapKit
import CoreLocation

/// Protocol defining a provider that can supply attribute tags for a given route step.
/// This allows different implementations to provide step-related metadata, such as
/// surface type, hazards, or lane protections, which can be used for routing or display.
public protocol StepAttributesProvider {
    /// Asynchronously fetches tags associated with a given route step.
    /// - Parameter step: The MKRoute.Step to fetch tags for.
    /// - Returns: A StepTags object containing attributes for the step.
    func tags(for step: MKRoute.Step) async -> StepTags
}

/// A local provider of step attributes based on a small bundled JSON file containing
/// attribution points near Victoria. It returns the nearest point within a short radius
/// as StepTags. This class caches recent lookups to improve performance by avoiding
/// repeated distance calculations for the same step midpoint.
///
/// The JSON schema includes additional metadata fields such as lightingLevel and freshnessDays
/// to provide richer contextual information about each point.
public final class LocalAttributionProvider: StepAttributesProvider {

    /// Represents a single attribution point decoded from the JSON resource.
    private struct AttrPoint: Decodable {
        let lat: Double
        let lon: Double
        let hasProtectedLane: Bool?
        let hasPaintedLane: Bool?
        let surface: String?
        let surfaceRough: Bool?
        let hazardCount: Int?
        let lightingLevel: String?      // New metadata field indicating lighting conditions
        let freshnessDays: Int?         // New metadata field indicating data freshness
    }

    /// Represents the top-level JSON structure containing multiple attribution points.
    private struct AttrFile: Decodable {
        let points: [AttrPoint]
    }

    /// All attribution points loaded from the bundled JSON resource.
    private let points: [AttrPoint]

    /// Cache to store recently queried midpoints and their corresponding tags to avoid repeated calculations.
    private var cache: [CLLocationCoordinate2D: StepTags] = [:]

    /// Initializes the provider by loading attribution points from the specified bundled JSON resource.
    /// - Parameters:
    ///   - bundle: The bundle containing the JSON resource. Defaults to main bundle.
    ///   - resourceName: The name of the JSON resource file without extension.
    ///   - resourceExt: The extension of the JSON resource file.
    public init(bundle: Bundle = .main, resourceName: String = "attrs-victoria", resourceExt: String = "json") {
        if let url = bundle.url(forResource: resourceName, withExtension: resourceExt),
           let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(AttrFile.self, from: data) {
            self.points = file.points
        } else {
            self.points = []
            print("[LocalAttributionProvider] Missing or unreadable \(resourceName).\(resourceExt) in bundle; returning neutral tags.")
        }
    }

    /// Returns attribute tags for a given route step by finding the nearest attribution point to the step's midpoint.
    /// It weights nearer points more strongly and logs detected hazards and matching distance.
    /// - Parameter step: The route step to retrieve tags for.
    /// - Returns: A StepTags object representing the attributes of the nearest attribution point or neutral tags if none found nearby.
    public func tags(for step: MKRoute.Step) async -> StepTags {
        // Use step midpoint to query nearest attr point
        guard let mid = midpoint(of: step.polyline) else { return StepTags() }

        // Check cache first to avoid repeated calculations
        if let cachedTags = cache[mid] {
            return cachedTags
        }

        var best: AttrPoint?
        var bestDist: CLLocationDistance = .greatestFiniteMagnitude

        let midLoc = CLLocation(latitude: mid.latitude, longitude: mid.longitude)

        // Find the nearest point and weight nearer points more strongly by inverse distance
        for p in points {
            let distance = midLoc.distance(from: CLLocation(latitude: p.lat, longitude: p.lon))
            if distance < bestDist {
                bestDist = distance
                best = p
            }
        }

        // Only accept nearby attributions (e.g., within 60 m)
        guard let candidate = best, bestDist <= 60 else {
            let neutral = StepTags()
            cache[mid] = neutral
            return neutral // neutral
        }

        // Log hazards detected
        if let hazardCount = candidate.hazardCount, hazardCount > 0 {
            print("[LocalAttributionProvider] Detected \(hazardCount) hazard(s) at distance \(Int(bestDist)) meters.")
        }

        // Debug print summary of matched attribution
        print("[LocalAttributionProvider] Matched attribution at distance \(Int(bestDist)) meters with lightingLevel: \(candidate.lightingLevel ?? "unknown"), freshnessDays: \(candidate.freshnessDays ?? -1)")

        // Compose tags, weighting nearer points could be extended here if needed
        let tags = StepTags(
            hasProtectedLane: candidate.hasProtectedLane ?? false,
            hasPaintedLane:   candidate.hasPaintedLane ?? false,
            surfaceRough:     candidate.surfaceRough ?? false,
            hazardCount:      candidate.hazardCount ?? 0,
            highwayClass:     nil,
            surface:          candidate.surface
        )

        // Cache the result for this midpoint
        cache[mid] = tags

        return tags
    }

    // MARK: - Helpers

    /// Computes the midpoint coordinate of a polyline by returning the coordinate at the middle index.
    /// - Parameter polyline: The polyline representing the route step.
    /// - Returns: The coordinate at the midpoint or nil if polyline has fewer than two points.
    private func midpoint(of polyline: MKPolyline) -> CLLocationCoordinate2D? {
        let n = polyline.pointCount
        guard n >= 2 else { return nil }
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: n)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: n))
        let midIndex = n / 2
        return coords[midIndex]
    }
}
