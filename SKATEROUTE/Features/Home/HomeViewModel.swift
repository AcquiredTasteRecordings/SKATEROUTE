// Features/Home/HomeViewModel.swift
// MVVM for the Home screen: source/destination selection, recents, and RideMode-aware navigation intent.

import Foundation
import Combine
import CoreLocation
import MapKit

// MARK: - Abstractions

/// Async one-shot current coordinate provider. Throw .denied when permission is blocked.
public enum HomeLocationError: Error { case denied, unavailable }

public typealias HomeCurrentLocationProvider = () async throws -> CLLocationCoordinate2D

/// Minimal coordinator abstraction to keep ViewModel decoupled from SwiftUI routing.
/// Allows the Home screen to request navigation with source/destination and the active ride mode.
public protocol HomeCoordinating: AnyObject {
    func presentMap(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, mode: RideMode)
}

// MARK: - Localization

private enum L10n {
    static let myLocation = NSLocalizedString("My Location", comment: "current location title")
    static let startMissing = NSLocalizedString("Start point missing.", comment: "validation")
    static let destinationMissing = NSLocalizedString("Destination missing.", comment: "validation")
    static let locDenied = NSLocalizedString("Location permission needed.", comment: "denied")
    static let locUnavailable = NSLocalizedString("Couldn’t get your location.", comment: "unavailable")
}

// MARK: - ViewModel

@MainActor
public final class HomeViewModel: ObservableObject {

    // MARK: Inputs / DI

    private let geocoder: GeocoderService
    private let currentLocationProvider: HomeCurrentLocationProvider?
    private let recents: HomeRecentsStore
    private weak var coordinator: HomeCoordinating?

    // MARK: UI State (bindables)

    @Published public var fromDisplay: String = L10n.myLocation
    @Published public var toDisplay: String = ""
    @Published public private(set) var fromCoord: CLLocationCoordinate2D? { didSet { updateCTAEnabled() } }
    @Published public private(set) var toCoord: CLLocationCoordinate2D? { didSet { updateCTAEnabled() } }

    @Published public private(set) var isResolvingLocation: Bool = false
    @Published public private(set) var errorMessage: String?

    @Published public private(set) var recentsList: [RecentPlace] = []

    /// Emits a navigation intent when inputs are valid and `go()` is called.
    @Published public private(set) var navIntent: (from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, mode: RideMode)?

    /// Derived state: primary CTA should be enabled when we have both endpoints.
    @Published public private(set) var isCTAEnabled: Bool = false

    // MARK: Internals

    private var lastReverseTask: Task<Void, Never>?

    // MARK: Init

    public init(geocoder: GeocoderService = GeocoderService(),
                currentLocationProvider: HomeCurrentLocationProvider?,
                recents: HomeRecentsStore = .shared,
                coordinator: HomeCoordinating?) {
        self.geocoder = geocoder
        self.currentLocationProvider = currentLocationProvider
        self.recents = recents
        self.coordinator = coordinator

        self.recentsList = recents.load()
        updateCTAEnabled()
    }

    // MARK: - Public API (used by HomeView)

    public func appear() {
        if fromCoord == nil {
            Task { await useMyLocation() }
        }
        recentsList = recents.load()
        updateCTAEnabled()
    }

    public func pickFrom(item: MKMapItem) {
        fromCoord = item.placemark.coordinate
        let (title, _) = GeocoderService.format(item.placemark, name: item.name)
        fromDisplay = title
        errorMessage = nil
    }

    public func pickTo(item: MKMapItem) {
        toCoord = item.placemark.coordinate
        let (title, _) = GeocoderService.format(item.placemark, name: item.name)
        toDisplay = title
        errorMessage = nil

        recents.saveOrPromote(RecentPlace(title: title, coordinate: item.placemark.coordinate))
        recentsList = recents.load()
    }

    public func swapEndpoints() {
        (fromCoord, toCoord) = (toCoord, fromCoord)
        (fromDisplay, toDisplay) = (toDisplay, fromDisplay)
        errorMessage = nil
        updateCTAEnabled()
    }

    public func clearFrom() {
        fromCoord = nil
        fromDisplay = ""
        updateCTAEnabled()
    }

    public func clearTo() {
        toCoord = nil
        toDisplay = ""
        updateCTAEnabled()
    }

    public func selectRecent(_ r: RecentPlace) {
        toCoord = r.coordinate
        toDisplay = r.title
        errorMessage = nil
    }

    /// Resolve current location (one-shot). If successful, it also reverse-geocodes for a friendlier label.
    public func useMyLocation() async {
        guard let provider = currentLocationProvider else { return }
        isResolvingLocation = true
        errorMessage = nil
        defer {
            isResolvingLocation = false
            updateCTAEnabled()
        }

        do {
            let coord = try await provider()
            fromCoord = coord
            fromDisplay = L10n.myLocation

            // Best-effort reverse geocode to refine the label
            lastReverseTask?.cancel()
            lastReverseTask = Task { [weak self] in
                guard let self else { return }
                if let pm = await self.geocoder.reverseGeocode(coord) {
                    let pretty = pm.name ?? pm.thoroughfare ?? pm.locality ?? self.fromDisplay
                    await MainActor.run { self.fromDisplay = pretty }
                }
            }
        } catch HomeLocationError.denied {
            errorMessage = L10n.locDenied
        } catch {
            errorMessage = L10n.locUnavailable
        }
    }

    /// Returns nil when valid, otherwise a localized validation message.
    public func validate() -> String? {
        if fromCoord == nil { return L10n.startMissing }
        if toCoord == nil { return L10n.destinationMissing }
        return nil
    }

    /// Validate and emit navigation intent, or forward directly to coordinator if injected.
    /// - Parameter mode: Ride mode to use for routing; defaults to the persisted rider preference.
    public func go(mode: RideMode? = nil) {
        errorMessage = validate()
        guard errorMessage == nil else { return }
        guard let src = fromCoord, let dst = toCoord else { return }

        let rideMode = mode ?? RideModeStore.load()

        if let coordinator {
            coordinator.presentMap(from: src, to: dst, mode: rideMode)
        } else {
            navIntent = (src, dst, rideMode)
        }
    }

    // MARK: - Private

    private func updateCTAEnabled() {
        isCTAEnabled = (fromCoord != nil && toCoord != nil)
    }
}

// MARK: - Recents Store (shared, lightweight, UserDefaults-backed)

public struct RecentPlace: Codable, Hashable, Identifiable {
    public var id: String { "\(coordinate.latitude),\(coordinate.longitude)" }
    public let title: String
    public let coordinate: CLLocationCoordinate2D

    public init(title: String, coordinate: CLLocationCoordinate2D) {
        self.title = title
        self.coordinate = coordinate
    }
}

public final class HomeRecentsStore {
    public static let shared = HomeRecentsStore()
    private let key = "HomeRecentsStore.items"
    private let maxCount = 12
    private init() {}

    public func load() -> [RecentPlace] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        guard let items = try? JSONDecoder().decode([SerializableRecentPlace].self, from: data) else { return [] }
        return items.map { $0.model }
    }

    public func saveOrPromote(_ place: RecentPlace) {
        var all = load()
        if let idx = all.firstIndex(of: place) {
            let item = all.remove(at: idx)
            all.insert(item, at: 0)
        } else {
            all.insert(place, at: 0)
        }
        if all.count > maxCount { all = Array(all.prefix(maxCount)) }
        if let data = try? JSONEncoder().encode(all.map { SerializableRecentPlace($0) }) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // Codable bridge for CLLocationCoordinate2D
    private struct SerializableRecentPlace: Codable {
        let title: String
        let lat: Double
        let lon: Double
        var model: RecentPlace { RecentPlace(title: title, coordinate: .init(latitude: lat, longitude: lon)) }
        init(_ m: RecentPlace) { self.title = m.title; self.lat = m.coordinate.latitude; self.lon = m.coordinate.longitude }
    }
}


