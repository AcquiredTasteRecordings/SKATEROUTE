// Services/RouteService.swift
// MapKit-first routing with grade summaries + step contexts.
// Async/await, memory-cached, privacy-safe, no secrets.

#if canImport(Support)
import Support
#endif
import Foundation
import CoreLocation
import MapKit

public final class RouteService: RoutingService {

    // MARK: Types

    public struct RouteCandidateMetadata: Codable, Sendable, Equatable {
        public let distanceMeters: CLLocationDistance
        public let expectedTravelTimeSeconds: TimeInterval
        public let gradeSummary: GradeSummary

        public init(distanceMeters: CLLocationDistance,
                    expectedTravelTimeSeconds: TimeInterval,
                    gradeSummary: GradeSummary) {
            self.distanceMeters = distanceMeters
            self.expectedTravelTimeSeconds = expectedTravelTimeSeconds
            self.gradeSummary = gradeSummary
        }

        public init(route: MKRoute, gradeSummary: GradeSummary) {
            self.init(distanceMeters: route.distance,
                      expectedTravelTimeSeconds: route.expectedTravelTime,
                      gradeSummary: gradeSummary)
        }

        public func makeGradeSummary() -> GradeSummary {
            gradeSummary
        }
    }

    public struct RouteCandidate: Sendable {
        public let id: String
        public let route: MKRoute
        public let gradeSummary: GradeSummary
        public let metadata: RouteCandidateMetadata
        public let stepContexts: [StepContext]
        // Room for future attributes (surface mix, hazard density, etc.)
        public init(id: String,
                    route: MKRoute,
                    gradeSummary: GradeSummary,
                    metadata: RouteCandidateMetadata,
                    stepContexts: [StepContext]) {
            self.id = id
            self.route = route
            self.gradeSummary = gradeSummary
            self.metadata = metadata
            self.stepContexts = stepContexts
        }
    }

    public enum RouteError: Error {
        case noRoutes
        case mapKitError(underlying: Error)
        case cancelled
    }

    // MARK: Dependencies

    private let elevation: ElevationServing
    private let contextBuilder: RouteContextBuilding

    // MARK: Cache

    private struct CacheKey: Hashable {
        let srcLat: Int32
        let srcLon: Int32
        let dstLat: Int32
        let dstLon: Int32
        let modeKey: String
        let legal: Bool

        init(source: CLLocationCoordinate2D, dest: CLLocationCoordinate2D, modeKey: String, legal: Bool) {
            // Quantize to ~1e-5 deg to avoid cache misses on tiny float drift
            srcLat = Int32((source.latitude * 1e5).rounded())
            srcLon = Int32((source.longitude * 1e5).rounded())
            dstLat = Int32((dest.latitude * 1e5).rounded())
            dstLon = Int32((dest.longitude * 1e5).rounded())
            self.modeKey = modeKey
            self.legal = legal
        }
    }

    private struct CachedValue {
        let routes: [MKRoute]
        let createdAt: Date
    }

    private let cacheTTL: TimeInterval = 8 * 60 // 8 minutes
    private var routeCache: [CacheKey: CachedValue] = [:]
    private let cacheQueue = DispatchQueue(label: "RouteService.Cache", qos: .userInitiated)

    // MARK: Lifecycle

    public init(elevation: ElevationServing, contextBuilder: RouteContextBuilding) {
        self.elevation = elevation
        self.contextBuilder = contextBuilder
    }

    // MARK: Public API (RoutingService)

    public func clearCache() {
        cacheQueue.sync { routeCache.removeAll() }
    }

    public func requestDirections(
        from source: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        mode: RideMode,
        preferSkateLegal: Bool
    ) async throws -> MKRoute {
        let all = try await routeOptions(
            from: source,
            to: destination,
            mode: mode,
            preferSkateLegal: preferSkateLegal
        )

        // Pick the best route by expected travel time (fastest) as a sane default.
        guard let best = all.map(\.route).min(by: { $0.expectedTravelTime < $1.expectedTravelTime }) else {
            throw RouteError.noRoutes
        }
        return best
    }

    public func routeOptions(
        from source: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        mode: RideMode,
        preferSkateLegal: Bool
    ) async throws -> [RouteCandidate] {
        // 1) MapKit directions (with memory cache)
        let routes = try await fetchRoutes(source: source, destination: destination, mode: mode, legal: preferSkateLegal)
        guard !routes.isEmpty else { throw RouteError.noRoutes }

        // 2) Per-route enrichment in parallel (grade summary + step contexts)
        return try await withThrowingTaskGroup(of: RouteCandidate.self) { group in
            for (idx, route) in routes.enumerated() {
                group.addTask { [elevation, contextBuilder] in
                    let summary = await elevation.summarizeGrades(on: route, sampleMeters: 75)
                    let contexts = await contextBuilder.context(for: route, gradeSummary: summary)
                    let id = Self.candidateId(route: route, index: idx)
                    let metadata = RouteCandidateMetadata(route: route, gradeSummary: summary)
                    return RouteCandidate(id: id,
                                          route: route,
                                          gradeSummary: summary,
                                          metadata: metadata,
                                          stepContexts: contexts)
                }
            }

            var out: [RouteCandidate] = []
            out.reserveCapacity(routes.count)
            do {
                while let cand = try await group.next() {
                    out.append(cand)
                }
            } catch {
                // Cancel remaining work if one task fails
                group.cancelAll()
                throw error
            }

            // Keep the same order as MapKit output for predictability
            return routes.compactMap { r in out.first(where: { $0.route === r }) }
        }
    }

    // MARK: MapKit core

    private func fetchRoutes(
        source: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        mode: RideMode,
        legal: Bool
    ) async throws -> [MKRoute] {
        let key = CacheKey(source: source, dest: destination, modeKey: mode.cacheKey, legal: legal)

        // Cache hit?
        if let cached = cacheQueue.sync(execute: { routeCache[key] }),
           Date().timeIntervalSince(cached.createdAt) < cacheTTL {
            return cached.routes
        }

        // Build request
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: source))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        req.transportType = mode.transportType
        req.requestsAlternateRoutes = true

        // Skate-legal bias: avoid highways/tolls to nudge paths away from roads we can’t ride.
        // For walking mode these flags are mostly no-ops but harmless.
        req.departureDate = Date() // encourages freshest MapKit data
        req.setValue(legal, forKey: "avoidsHighways") // KVC: public property on MKDirections.Request
        req.setValue(legal, forKey: "avoidsTolls")

        let dir = MKDirections(request: req)

        do {
            let response = try await dir.calculate()
            let routes = response.routes
            guard !routes.isEmpty else { throw RouteError.noRoutes }

            // Store to cache
            cacheQueue.sync { routeCache[key] = CachedValue(routes: routes, createdAt: Date()) }
            return routes
        } catch is CancellationError {
            throw RouteError.cancelled
        } catch {
            throw RouteError.mapKitError(underlying: error)
        }
    }

    // MARK: Utilities

    private static func candidateId(route: MKRoute, index: Int) -> String {
        // Build a stable-ish id from geometry + ETA
        var hasher = Hasher()
        hasher.combine(index)
        hasher.combine(Int(route.distance.rounded()))
        hasher.combine(Int(route.expectedTravelTime.rounded()))
        hasher.combine(route.polyline.pointCount)
        return String(hasher.finalize(), radix: 16, uppercase: false)
    }
}

// MARK: - RideMode → MapKit mapping

private extension RideMode {
    /// Stable key to bucket caches by mode. We don’t assume specific cases.
    var cacheKey: String {
        String(reflecting: self)
    }

    /// Transport mapping — MapKit has no “bicycle” or “skateboard”; walking is the safest baseline.
    /// If your RideMode later includes car/van support (for shuttle-to-spot), extend this as needed.
    var transportType: MKDirectionsTransportType {
        // Default to walking; conservative and skate-legal.
        return .walking
    }
}


