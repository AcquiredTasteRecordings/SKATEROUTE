// Services/GeocoderService.swift
import Foundation
import MapKit
import CoreLocation

/// `GeocoderService` is a utility within SKATEROUTE responsible for handling both forward and reverse geocoding operations.
/// It provides asynchronous methods to search for locations by query or coordinates, enhancing app responsiveness and user experience.
/// This service includes caching, request throttling, analytics logging, and error handling to optimize geocoding requests.
public struct GeocoderService {
    public init() {}

    // MARK: - Private Properties

    /// Cache for storing forward geocoding results keyed by query string to improve responsiveness for frequent queries.
    private static var forwardCache = NSCache<NSString, NSArray>()

    /// Dictionary to keep track of ongoing forward geocoding tasks to prevent duplicate simultaneous requests for the same query.
    private static var ongoingForwardRequests = [String: Task<[MKMapItem], Error>]()

    /// Counters for analytics logging to track number of forward and reverse lookups performed.
    private static var forwardLookupCount = 0
    private static var reverseLookupCount = 0

    // MARK: - Public Methods

    /// Performs forward geocoding (search) for addresses and points of interest (POIs) based on a natural language query.
    ///
    /// - Parameters:
    ///   - query: The search string representing the location or POI to find.
    ///   - region: Optional region to bias the search results geographically.
    ///   - useAppleMapsPriority: Optional boolean to bias results toward Apple-verified POIs. Defaults to false.
    ///
    /// - Returns: An array of `MKMapItem` objects matching the query.
    ///
    /// - Throws: An error if the search fails due to network issues, invalid queries, or no results found.
    public func forward(query: String, near region: MKCoordinateRegion? = nil, useAppleMapsPriority: Bool = false) async throws -> [MKMapItem] {
        // Return cached results if available
        if let cached = GeocoderService.forwardCache.object(forKey: query as NSString) as? [MKMapItem] {
            return cached
        }

        // Throttle duplicate requests for the same query
        if let ongoingTask = GeocoderService.ongoingForwardRequests[query] {
            return try await ongoingTask.value
        }

        let task = Task<[MKMapItem], Error> {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            if let region = region { request.region = region }

            // Bias toward Apple-verified POIs if requested by adjusting the point of interest filter
            if useAppleMapsPriority {
                if #available(iOS 16.0, *) {
                    request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.airport, .amusementPark, .aquarium, .artGallery, .bakery, .bank, .bar, .cafe, .campground, .carRental, .clothingStore, .convenienceStore, .dentist, .departmentStore, .doctor, .electronicsStore, .florist, .fuel, .furnitureStore, .gym, .hairCare, .hardwareStore, .homeGoodsStore, .hospital, .hotel, .laundry, .library, .movieTheater, .museum, .nightlife, .park, .parking, .pharmacy, .postOffice, .restaurant, .school, .shoeStore, .shoppingCenter, .spa, .stadium, .supermarket, .theater, .university, .zoo])
                }
            }

            let search = MKLocalSearch(request: request)

            do {
                let response = try await search.start()
                let items = response.mapItems

                if items.isEmpty {
                    throw GeocoderServiceError.noResultsFound(query: query)
                }

                // Cache the results
                GeocoderService.forwardCache.setObject(items as NSArray, forKey: query as NSString)

                // Increment analytics count
                GeocoderService.forwardLookupCount += 1

                return items
            } catch {
                throw GeocoderServiceError.forwardGeocodingFailed(underlyingError: error)
            }
        }

        GeocoderService.ongoingForwardRequests[query] = task
        defer { GeocoderService.ongoingForwardRequests.removeValue(forKey: query) }

        return try await task.value
    }

    /// Performs reverse geocoding to convert geographic coordinates into human-readable place names or addresses.
    ///
    /// - Parameter location: The coordinate to reverse geocode.
    ///
    /// - Returns: An array of `MKMapItem` objects representing the placemarks at the coordinate.
    ///
    /// - Throws: An error if reverse geocoding fails due to network issues or no placemarks found.
    public func reverse(location: CLLocationCoordinate2D) async throws -> [MKMapItem] {
        let cg = CLGeocoder()
        do {
            let placemarks = try await cg.reverseGeocodeLocation(
                CLLocation(latitude: location.latitude, longitude: location.longitude)
            )
            if placemarks.isEmpty {
                throw GeocoderServiceError.noResultsFound(location: location)
            }
            GeocoderService.reverseLookupCount += 1
            return placemarks.map { MKMapItem(placemark: MKPlacemark(placemark: $0)) }
        } catch {
            throw GeocoderServiceError.reverseGeocodingFailed(underlyingError: error)
        }
    }

    // MARK: - Analytics Accessors

    /// Returns the total number of forward geocoding lookups performed.
    public static func forwardLookupsCount() -> Int {
        return forwardLookupCount
    }

    /// Returns the total number of reverse geocoding lookups performed.
    public static func reverseLookupsCount() -> Int {
        return reverseLookupCount
    }

    // MARK: - Error Types

    /// Errors that can be thrown by `GeocoderService` methods.
    public enum GeocoderServiceError: LocalizedError {
        case noResultsFound(query: String)
        case noResultsFound(location: CLLocationCoordinate2D)
        case forwardGeocodingFailed(underlyingError: Error)
        case reverseGeocodingFailed(underlyingError: Error)

        public var errorDescription: String? {
            switch self {
            case .noResultsFound(let query):
                return "No results found for query: \"\(query)\"."
            case .noResultsFound(let location):
                return "No placemarks found at location: (\(location.latitude), \(location.longitude))."
            case .forwardGeocodingFailed(let underlyingError):
                return "Forward geocoding failed: \(underlyingError.localizedDescription)"
            case .reverseGeocodingFailed(let underlyingError):
                return "Reverse geocoding failed: \(underlyingError.localizedDescription)"
            }
        }
    }
}
