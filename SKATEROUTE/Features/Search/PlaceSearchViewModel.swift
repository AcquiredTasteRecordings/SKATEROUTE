// Features/Search/PlaceSearchViewModel.swift
// MVVM for place search: debounced, cancel-safe, and MapKit-first.

import Foundation
import Combine
import MapKit
import CoreLocation

// MARK: - Current location provider

/// Async provider for a one-shot current coordinate (e.g., via CLLocationManager).
/// Throw `.denied` when permission is missing and `.unavailable` for other failures.
public enum CurrentLocationError: Error {
    case denied
    case unavailable
}

public typealias CurrentLocationProvider = () async throws -> CLLocationCoordinate2D

// MARK: - ViewModel

@MainActor
public final class PlaceSearchViewModel: ObservableObject {

    // Inputs / DI
    private let geocoder: GeocoderService
    private let presetRegion: MKCoordinateRegion?
    private let currentLocationProvider: CurrentLocationProvider?

    // UI State
    @Published public var query: String = "" {
        didSet { scheduleSearchDebounced() }
    }
    @Published public private(set) var isSearching: Bool = false
    @Published public private(set) var suggestions: [PlaceSuggestion] = []
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var canUseCurrentLocation: Bool
    @Published public private(set) var selected: PlaceSuggestion?

    // Internal
    private var debounceTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private let debounceInterval: UInt64 = 250_000_000 // 250ms

    // MARK: - Init

    /// - Parameters:
    ///   - geocoder: MapKit-backed geocoder/search service.
    ///   - presetRegion: Optional region to bias search results (camera/city).
    ///   - currentLocationProvider: Async provider for one-shot current location.
    ///   - allowUseCurrentLocation: Expose "Use my location" affordance.
    public init(geocoder: GeocoderService = GeocoderService(),
                presetRegion: MKCoordinateRegion? = nil,
                currentLocationProvider: CurrentLocationProvider? = nil,
                allowUseCurrentLocation: Bool = true) {
        self.geocoder = geocoder
        self.presetRegion = presetRegion
        self.currentLocationProvider = currentLocationProvider
        self.canUseCurrentLocation = allowUseCurrentLocation && currentLocationProvider != nil
    }

    // MARK: - Public API

    /// Force a search immediately (bypasses debounce).
    public func searchNow() {
        runSearch(trim(query))
    }

    /// Select a suggestion produced by this VM.
    public func select(_ suggestion: PlaceSuggestion) {
        selected = suggestion
    }

    /// Use the current location if available; sets `selected` to a synthetic suggestion.
    public func useCurrentLocation() async {
        guard canUseCurrentLocation, let provider = currentLocationProvider else { return }
        isSearching = true
        errorMessage = nil
        do {
            let coord = try await provider()
            let item = MKMapItem(placemark: MKPlacemark(coordinate: coord))
            let my = PlaceSuggestion(
                id: "my-location",
                title: NSLocalizedString("My Location", comment: "current location title"),
                subtitle: "",
                coordinate: coord,
                item: item
            )
            selected = my
            isSearching = false
        } catch CurrentLocationError.denied {
            errorMessage = NSLocalizedString("Location permission needed.", comment: "location denied")
            isSearching = false
        } catch {
            errorMessage = NSLocalizedString("Couldn’t get your location.", comment: "location unavailable")
            isSearching = false
        }
    }

    /// Cancel in-flight work (use on disappear).
    public func cancel() {
        debounceTask?.cancel(); debounceTask = nil
        searchTask?.cancel(); searchTask = nil
        geocoder.cancel()
    }

    // MARK: - Private

    private func scheduleSearchDebounced() {
        // Reset state when clearing input
        if trim(query).isEmpty {
            suggestions = []
            errorMessage = nil
        }

        debounceTask?.cancel()
        let q = trim(query)
        debounceTask = Task { [weak self] in
            guard let self else { return }
            // Debounce
            try? await Task.sleep(nanoseconds: debounceInterval)
            await self.runSearch(q)
        }
    }

    private func runSearch(_ q: String) {
        // Cancel any active search task
        searchTask?.cancel()
        geocoder.cancel()

        guard !q.isEmpty else {
            isSearching = false
            return
        }

        isSearching = true
        errorMessage = nil
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await self.geocoder.searchPlaces(query: q, near: self.presetRegion)
                await MainActor.run {
                    self.suggestions = results
                    self.isSearching = false
                }
            } catch is CancellationError {
                // Ignore, replaced by a newer search
            } catch {
                await MainActor.run {
                    self.suggestions = []
                    self.isSearching = false
                    self.errorMessage = NSLocalizedString("No results found.", comment: "search error fallback")
                }
            }
        }
    }

    private func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Preview helper (fake location provider)

#if DEBUG
public enum PreviewLocationProvider {
    public static func success(_ coord: CLLocationCoordinate2D) -> CurrentLocationProvider {
        return {
            try await Task.sleep(nanoseconds: 200_000_000)
            return coord
        }
    }
    public static func denied() -> CurrentLocationProvider {
        return {
            try await Task.sleep(nanoseconds: 100_000_000)
            throw CurrentLocationError.denied
        }
    }
}
#endif


