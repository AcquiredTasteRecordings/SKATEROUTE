// Services/RouteService.swift
import Foundation
import MapKit

/// `RouteService` is responsible for fetching and adapting routes specifically tailored for skating.
/// It fetches walking-style routes from MapKit and adapts them by optionally filtering out skate-restricted paths.
/// The service also caches routes to improve performance on repeated requests.
public final class RouteService {
    public static let shared = RouteService()
    private init() {}

    private let routeCache = NSCache<NSString, MKRoute>()

    /// Requests a walking-style route adapted for skating preferences between two coordinates.
    ///
    /// - Parameters:
    ///   - source: The starting coordinate.
    ///   - destination: The ending coordinate.
    ///   - preferSkateLegal: If true (default), attempts to filter out routes with skate-restricted paths using MapKit metadata.
    /// - Returns: An `MKRoute` representing the best route for skating.
    /// - Throws: An error if no route is found or the request fails.
    public func requestDirections(from source: CLLocationCoordinate2D,
                                  to destination: CLLocationCoordinate2D,
                                  preferSkateLegal: Bool = true) async throws -> MKRoute {
        let cacheKey = "\(source.latitude),\(source.longitude)-\(destination.latitude),\(destination.longitude)-\(preferSkateLegal)" as NSString
        if let cachedRoute = routeCache.object(forKey: cacheKey) {
            logRouteDetails(route: cachedRoute, cached: true)
            return cachedRoute
        }

        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: source))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        req.transportType = .walking

        let directions = MKDirections(request: req)

        let response: MKDirections.Response
        if #available(iOS 16.0, *) {
            response = try await directions.calculate()
        } else {
            // Backward compatibility for earlier iOS versions
            response = try await withCheckedThrowingContinuation { continuation in
                directions.calculate { resp, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let resp = resp {
                        continuation.resume(returning: resp)
                    } else {
                        continuation.resume(throwing: NSError(domain: "RouteService", code: 500, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
                    }
                }
            }
        }

        var route = response.routes.first
        if route == nil {
            throw NSError(domain: "RouteService", code: 404, userInfo: [NSLocalizedDescriptionKey: "No route found"])
        }

        // Filter out skate-restricted steps if requested and metadata is available
        if preferSkateLegal, let originalRoute = route {
            let filteredSteps = originalRoute.steps.filter { step in
                // Attempt to exclude steps that are marked as restricted for skating
                if #available(iOS 16.0, *) {
                    if let restrictions = step.transportTypeRestrictions {
                        // Exclude steps restricted for pedestrian or skating if such metadata exists
                        // Since MapKit does not directly expose skating restrictions,
                        // we approximate by excluding steps marked as private or restricted if possible.
                        if restrictions.contains(.privateRoad) || restrictions.contains(.restricted) {
                            return false
                        }
                    }
                }
                return true
            }
            if !filteredSteps.isEmpty {
                // Create a new MKRoute with filtered steps if possible
                // MKRoute is not publicly initializable, so fallback to original route if filtering is partial
                // Here we just replace the steps array using KVC as a workaround, if allowed.
                // Otherwise, we keep original route.
                let mutableRoute = originalRoute.mutableCopy() as? MKRoute
                if let mutableRoute = mutableRoute {
                    mutableRoute.setValue(filteredSteps, forKey: "steps")
                    route = mutableRoute
                }
            }
        }

        if let route = route {
            routeCache.setObject(route, forKey: cacheKey)
            logRouteDetails(route: route, cached: false)
            return route
        } else {
            throw NSError(domain: "RouteService", code: 404, userInfo: [NSLocalizedDescriptionKey: "No route found after filtering"])
        }
    }

    /// Clears the cached routes stored in the service.
    public func clearCache() {
        routeCache.removeAllObjects()
    }

    private func logRouteDetails(route: MKRoute, cached: Bool) {
        let source = cached ? "Cache" : "Network"
        print("[RouteService] \(source) Route - Distance: \(route.distance) meters, Duration: \(route.expectedTravelTime) seconds, Steps: \(route.steps.count)")
    }
}
