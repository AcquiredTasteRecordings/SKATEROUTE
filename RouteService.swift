// Services/RouteService.swift
import Foundation
import MapKit
import CoreLocation

/// `RouteService` is responsible for fetching MapKit directions and enriching them with
/// skating-specific metadata such as slope summaries and surface context.
/// It supports fetching alternate routes in a single request and produces a
/// collection of `RouteCandidate` values that can be scored and presented to the user.
public final class RouteService {
    // MARK: - Types

       public struct RouteCandidate: Identifiable {
           public let id: String
           public let route: MKRoute
           public let metadata: RouteCandidateMetadata
       }

       public struct RouteCandidateMetadata: Codable {
           public struct SurfaceSummary: Codable {
               public let dominantSurface: String?
               public let roughFraction: Double
               public let protectedFraction: Double
               public let paintedFraction: Double

               public init(dominantSurface: String?,
                           roughFraction: Double,
                           protectedFraction: Double,
                           paintedFraction: Double) {
                   self.dominantSurface = dominantSurface
                   self.roughFraction = roughFraction
                   self.protectedFraction = protectedFraction
                   self.paintedFraction = paintedFraction
               }
           }

           public let grade: GradeSummary
           public let surface: SurfaceSummary
           public let stepContexts: [StepContext]
           public let hazardCount: Int

           public init(grade: GradeSummary,
                       surface: SurfaceSummary,
                       stepContexts: [StepContext],
                       hazardCount: Int) {
               self.grade = grade
               self.surface = surface
               self.stepContexts = stepContexts
               self.hazardCount = hazardCount
           }
       }

       // MARK: - Properties

    private let routeCache = NSCache<NSString, MKRoute>()
    private let elevation: ElevationServing
       private let contextBuilder: RouteContextBuilding

       public init(elevation: ElevationServing,
                   contextBuilder: RouteContextBuilding) {
           self.elevation = elevation
           self.contextBuilder = contextBuilder
       }
    
    // MARK: - Public API

       /// Requests a single best route (for callers that haven't migrated to the options API yet).
    /// - Parameters:
    ///   - source: The starting coordinate.
    ///   - destination: The destination coordinate.
        ///   - preferSkateLegal: When true the service attempts to filter steps that look restricted.
        /// - Returns: The first route candidate returned by MapKit after optional filtering.
    public func requestDirections(from source: CLLocationCoordinate2D,
                                  to destination: CLLocationCoordinate2D,
                                  preferSkateLegal: Bool = true) async throws -> MKRoute {
        let options = try await routeOptions(from: source,
                                                    to: destination,
                                                    preferSkateLegal: preferSkateLegal)
               guard let first = options.first?.route else {
                   throw NSError(domain: "RouteService", code: 404, userInfo: [NSLocalizedDescriptionKey: "No routes returned"])
        }
        return first
           }
    
    /// Requests alternate route candidates between the provided coordinates.
        /// Metadata for each candidate includes slope summaries and surface composition
        /// which can be fed into the scoring pipeline.
        public func routeOptions(from source: CLLocationCoordinate2D,
                                 to destination: CLLocationCoordinate2D,
                                 preferSkateLegal: Bool = true) async throws -> [RouteCandidate] {
            let cacheKey = cacheKeyForOptions(source: source, destination: destination, preferSkateLegal: preferSkateLegal)
            if let cached = routeCache.object(forKey: cacheKey as NSString) {
                return try await enrichCachedRoute(cached, cacheKey: cacheKey)
            }

            let request = MKDirections.Request()
                    request.source = MKMapItem(placemark: MKPlacemark(coordinate: source))
                    request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
                    request.transportType = .walking
                    request.requestsAlternateRoutes = true
            
            let directions = MKDirections(request: request)
        let response: MKDirections.Response
        if #available(iOS 16.0, *) {
            response = try await directions.calculate()
        } else {
            response = try await withCheckedThrowingContinuation { continuation in
                directions.calculate { resp, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let resp = resp {
                        continuation.resume(returning: resp)
                    } else {
                        continuation.resume(throwing: NSError(domain: "RouteService",
                                                                                       code: 500,
                                                                                       userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
                    }
                }
            }
        }

            let routes = response.routes
                    guard !routes.isEmpty else {
            throw NSError(domain: "RouteService", code: 404, userInfo: [NSLocalizedDescriptionKey: "No route found"])
        }

            let adaptedRoutes = routes.map { preferSkateLegal ? filterRestrictedSteps(on: $0) : $0 }

                    var enriched: [RouteCandidate] = []
                    enriched.reserveCapacity(adaptedRoutes.count)

                    try await withThrowingTaskGroup(of: RouteCandidate?.self) { group in
                        for route in adaptedRoutes {
                            group.addTask { [weak self] in
                                guard let self else { return nil }
                                let metadata = await self.buildMetadata(for: route)
                                return RouteCandidate(id: self.identifier(for: route),
                                                      route: route,
                                                      metadata: metadata)
                            }
                        }
    
                        for try await candidate in group {
                            if let candidate { enriched.append(candidate) }
                        }
                    }
            
            // Cache the fastest (first) route for quick lookup and reuse.
                   if let fastest = enriched.min(by: { $0.route.expectedTravelTime < $1.route.expectedTravelTime }) {
                       routeCache.setObject(fastest.route, forKey: cacheKey as NSString)
                   }

                   return enriched.sorted { lhs, rhs in
                       if lhs.route.expectedTravelTime == rhs.route.expectedTravelTime {
                           return lhs.route.distance < rhs.route.distance
                       }
                       return lhs.route.expectedTravelTime < rhs.route.expectedTravelTime
                   }
               }

    /// Clears the cached fastest route entry for a given source/destination pair.
        public func clearCache() {
            routeCache.removeAllObjects()
        }
   
    // MARK: - Helpers

       private func enrichCachedRoute(_ route: MKRoute, cacheKey: String) async throws -> [RouteCandidate] {
           let metadata = await buildMetadata(for: route)
           return [RouteCandidate(id: identifier(for: route), route: route, metadata: metadata)]
       }

       private func buildMetadata(for route: MKRoute) async -> RouteCandidateMetadata {
           async let gradeSummary = elevation.summarizeGrades(on: route)
           async let stepContext = contextBuilder.context(for: route)

           let grade = await gradeSummary
           let context = await stepContext
           let surfaceSummary = summarizeSurface(context)
           let hazards = context.reduce(0) { $0 + $1.tags.hazardCount }

           return RouteCandidateMetadata(grade: grade,
                                         surface: surfaceSummary,
                                         stepContexts: context,
                                         hazardCount: hazards)
       }

       private func summarizeSurface(_ contexts: [StepContext]) -> RouteCandidateMetadata.SurfaceSummary {
           guard !contexts.isEmpty else {
               return .init(dominantSurface: nil, roughFraction: 0, protectedFraction: 0, paintedFraction: 0)
           }

           var surfaceHistogram: [String: Int] = [:]
           var rough: Double = 0
           var protected: Double = 0
           var painted: Double = 0

           for ctx in contexts {
               if ctx.tags.surfaceRough { rough += 1 }
               if ctx.tags.hasProtectedLane { protected += 1 }
               if ctx.tags.hasPaintedLane { painted += 1 }
               if let surface = ctx.tags.surface {
                   surfaceHistogram[surface, default: 0] += 1
               }
           }

           let dominant = surfaceHistogram.max(by: { $0.value < $1.value })?.key
           let total = Double(contexts.count)

           return .init(dominantSurface: dominant,
                         roughFraction: rough / total,
                         protectedFraction: protected / total,
                         paintedFraction: painted / total)
       }

       private func filterRestrictedSteps(on route: MKRoute) -> MKRoute {
           guard let mutable = route.mutableCopy() as? MKRoute else { return route }
           let filteredSteps = route.steps.filter { step in
               guard step.distance > 0 else { return true }
               if #available(iOS 16.0, *) {
                   if let restrictions = step.transportTypeRestrictions {
                       if restrictions.contains(.privateRoad) || restrictions.contains(.restricted) {
                           return false
                       }
                   }
               }
               return true
           }
           mutable.setValue(filteredSteps, forKey: "steps")
           return mutable
       }

       private func identifier(for route: MKRoute) -> String {
           let hashComponents: [String] = [String(route.expectedTravelTime),
                                           String(route.distance),
                                           route.name ?? ""]
           return hashComponents.joined(separator: "-")
       }

       private func cacheKeyForOptions(source: CLLocationCoordinate2D,
                                       destination: CLLocationCoordinate2D,
                                       preferSkateLegal: Bool) -> String {
           "\(source.latitude),\(source.longitude)-\(destination.latitude),\(destination.longitude)-\(preferSkateLegal)"
       }
   }
