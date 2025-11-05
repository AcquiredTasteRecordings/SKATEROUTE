// Features/Home/HomeViewModel.swift
import Foundation
import CoreLocation
import Combine

/// View model for the Home screen.
/// - Knows: start/destination, selected ride mode, and basic rider stats (distance, spots, badges).
/// - Does: triggers navigation when user taps "Find Smooth Line".
@MainActor
public final class HomeViewModel: ObservableObject {

    // MARK: - Routing
    @Published public var source: CLLocationCoordinate2D? =
        CLLocationCoordinate2D(latitude: 48.4634, longitude: -123.3117) // UVic
    @Published public var destination: CLLocationCoordinate2D? =
        CLLocationCoordinate2D(latitude: 48.4203, longitude: -123.3852) // Wharf
    @Published public var selectedMode: RideMode = .smoothest

    // MARK: - Rider stats (for Home hero section)
    @Published public private(set) var totalDistanceMeters: Double = 0
    @Published public private(set) var totalSpots: Int = 0
    @Published public private(set) var badgesCount: Int = 0

    private let navigateAction: (CLLocationCoordinate2D, CLLocationCoordinate2D, RideMode) -> Void
    private let store = UserDefaults.standard

    // Keys for persistence
    private enum Keys {
        static let totalDistanceMeters = "home.totalDistanceMeters"
        static let totalSpots = "home.totalSpots"
        static let badgesCount = "home.badgesCount"
    }

    public init(navigate: @escaping (CLLocationCoordinate2D, CLLocationCoordinate2D, RideMode) -> Void) {
        self.navigateAction = navigate
        loadStats()
    }

    // MARK: - Actions

    public func navigate() {
        guard let src = source, let dst = destination else { return }
        navigateAction(src, dst, selectedMode)
    }

    /// Called when the user drops a spot or reports a surface.
    public func incrementSpots() {
        totalSpots += 1
        persistStats()
    }

    /// Called when a ride finishes and we know how far they rode.
    public func addDistance(meters: Double) {
        totalDistanceMeters += meters
        persistStats()
    }

    /// For future challenges / badges UI.
    public func addBadge() {
        badgesCount += 1
        persistStats()
    }

    public func resetStats() {
        totalDistanceMeters = 0
        totalSpots = 0
        badgesCount = 0
        persistStats()
    }

    // MARK: - Derived

    public var totalDistanceKilometersFormatted: String {
        let km = totalDistanceMeters / 1000.0
        return String(format: "%.1f km", km)
    }

    public var spotsFormatted: String {
        "\(totalSpots) spots"
    }

    public var badgesFormatted: String {
        badgesCount == 1 ? "1 badge" : "\(badgesCount) badges"
    }

    // MARK: - Persistence

    private func loadStats() {
        totalDistanceMeters = store.double(forKey: Keys.totalDistanceMeters)
        totalSpots = store.integer(forKey: Keys.totalSpots)
        badgesCount = store.integer(forKey: Keys.badgesCount)
    }

    private func persistStats() {
        store.set(totalDistanceMeters, forKey: Keys.totalDistanceMeters)
        store.set(totalSpots, forKey: Keys.totalSpots)
        store.set(badgesCount, forKey: Keys.badgesCount)
    }
}
