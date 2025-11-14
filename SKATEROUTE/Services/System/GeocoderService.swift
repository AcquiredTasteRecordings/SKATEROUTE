// Services/GeocoderService.swift
// MapKit-first geocoding + place search with cancel-safety, small LRU cache, and clean formatting.

import Foundation
import CoreLocation
import MapKit

/// Lightweight suggestion model suitable for list UIs.
/// Keep the MapKit item to allow 1-tap navigation to directions.
public struct PlaceSuggestion: Identifiable, Hashable {
    public let id: String           // stable-ish id from MapKit result
    public let title: String        // primary line
    public let subtitle: String     // secondary line (locality, admin area, etc.)
    public let coordinate: CLLocationCoordinate2D
    public let item: MKMapItem

    public init(id: String, title: String, subtitle: String, coordinate: CLLocationCoordinate2D, item: MKMapItem) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.coordinate = coordinate
        self.item = item
    }
}

/// Geocoder + local search service. MapKit-only, no secrets, cancel-safe.
/// Scope: forward search (`searchPlaces`) and reverse geocode (`reverseGeocode`).
@MainActor
public final class GeocoderService: ObservableObject {

    // MARK: - Internals

    private let geocoder = CLGeocoder()
    private var currentSearch: MKLocalSearch?

    // Small in-memory cache to reduce repeated network hits while typing.
    private let cache = QueryCache<String, [PlaceSuggestion]>(capacity: 32)
    private let reverseCache = QueryCache<String, CLPlacemark>(capacity: 64)

    public init() {}

    // MARK: - Public API

    /// Forward search for places matching `query`. Optionally bias by a region (recommended).
    /// - Parameters:
    ///   - query: Natural language query; trimmed; must be non-empty.
    ///   - near: Optional coordinate region to bias results (e.g., camera region).
    /// - Returns: Up to ~20 suggestions from MKLocalSearch, normalized to `PlaceSuggestion`.
    public func searchPlaces(query: String, near region: MKCoordinateRegion? = nil) async throws -> [PlaceSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Cache hit?
        let cacheKey = Self.cacheKey(for: trimmed, region: region)
        if let hit = cache.value(forKey: cacheKey) { return hit }

        // Cancel any in-flight search (debounced UIs will call frequently).
        currentSearch?.cancel()

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        if let region { request.region = region }
        // Prefer points of interest and addresses; avoid web results
        request.resultTypes = [.pointOfInterest, .address]

        let search = MKLocalSearch(request: request)
        currentSearch = search

        do {
            let resp = try await search.start()
            let items = resp.mapItems

            let suggestions: [PlaceSuggestion] = items.prefix(25).compactMap { item in
                guard let coord = item.placemark.location?.coordinate else { return nil }
                let (title, subtitle) = Self.format(item.placemark, name: item.name)
                let id = Self.stableId(for: item)
                return PlaceSuggestion(id: id, title: title, subtitle: subtitle, coordinate: coord, item: item)
            }

            cache.setValue(suggestions, forKey: cacheKey)
            return suggestions
        } catch is CancellationError {
            // Swallow and return empty; caller likely launched a newer search.
            return []
        } catch {
            // MapKit sometimes throws generic errors for empty result sets; normalize to empty.
            return []
        }
    }

    /// Reverse geocode a coordinate into a human-friendly placemark (cached).
    public func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async -> CLPlacemark? {
        let key = Self.reverseKey(for: coordinate, precision: 5)
        if let cached = reverseCache.value(forKey: key) { return cached }

        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(
                CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
                preferredLocale: .current
            )
            if let pm = placemarks.first {
                reverseCache.setValue(pm, forKey: key)
                return pm
            }
        } catch is CancellationError {
            return nil
        } catch {
            return nil
        }
        return nil
    }

    /// Cancel any in-flight forward search.
    public func cancel() {
        currentSearch?.cancel()
        geocoder.cancelGeocode()
    }

    // MARK: - Formatting Helpers

    /// Returns (title, subtitle) for UI from an `MKPlacemark` and optional `name`.
    public static func format(_ placemark: MKPlacemark, name: String?) -> (String, String) {
        // Title preference: explicit name > thoroughfare+subThoroughfare > locality
        let title: String = {
            if let name, !name.isEmpty { return name }
            if let street = placemark.thoroughfare {
                if let num = placemark.subThoroughfare { return "\(num) \(street)" }
                return street
            }
            return placemark.locality ?? placemark.title ?? "Dropped Pin"
        }()

        // Subtitle preference: locality, admin area, country — skip duplicates
        var parts: [String] = []
        if let n = placemark.subLocality, !n.equalsCaseInsensitive(title) { parts.append(n) }
        if let city = placemark.locality, !city.equalsCaseInsensitive(title) { parts.append(city) }
        if let admin = placemark.administrativeArea, !admin.equalsCaseInsensitive(title) { parts.append(admin) }
        if let country = placemark.country, !country.equalsCaseInsensitive(title) { parts.append(country) }
        let subtitle = parts.joined(separator: ", ")

        return (title, subtitle)
    }

    // MARK: - Keys / IDs

    private static func cacheKey(for query: String, region: MKCoordinateRegion?) -> String {
        if let r = region {
            let lat = Int((r.center.latitude * 1e2).rounded())
            let lon = Int((r.center.longitude * 1e2).rounded())
            let spanLat = Int((r.span.latitudeDelta * 1e2).rounded())
            let spanLon = Int((r.span.longitudeDelta * 1e2).rounded())
            return "\(query.lowercased())|\(lat),\(lon)|\(spanLat)x\(spanLon)"
        }
        return query.lowercased()
    }

    private static func reverseKey(for c: CLLocationCoordinate2D, precision: Int) -> String {
        let p = pow(10.0, Double(precision))
        let lat = (c.latitude * p).rounded() / p
        let lon = (c.longitude * p).rounded() / p
        return "\(lat),\(lon)"
    }

    private static func stableId(for item: MKMapItem) -> String {
        // Prefer MapKit's uniqueID if present; otherwise hash name+coord.
        if #available(iOS 16.0, *) {
            if let uid = item.placemark.pointOfInterestCategory?.rawValue { return uid }
        }
        var hasher = Hasher()
        hasher.combine(item.name ?? "")
        let c = item.placemark.coordinate
        hasher.combine(Int((c.latitude * 1e6).rounded()))
        hasher.combine(Int((c.longitude * 1e6).rounded()))
        return String(hasher.finalize(), radix: 16)
    }
}

// MARK: - String util

private extension String {
    func equalsCaseInsensitive(_ other: String) -> Bool {
        self.caseInsensitiveCompare(other) == .orderedSame
    }
}


