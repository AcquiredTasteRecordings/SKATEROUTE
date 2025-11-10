// Features/Map/SaveRouteButton.swift
// One-tap save and optional offline prefetch for the current route.
// - Primary tap toggles favorite for the active MKRoute (or its summary).
// - Long-press (or secondary control) toggles Offline Pack prefetch for the saved route corridor.
// - Integrates with Services/Favorites/RouteFavoritesStore + Services/Offline/TileFetcher.
// - A11y: VO label “Save route”; state-driven value (“Saved”, “Not saved”, “Offline ready”); ≥44pt hit target.
// - Perf: prefetch runs in background with progress callback; UI is optimistic but rolls back on failure.
// - Privacy: no location reads here; operates on the provided route summary/polyline only.

import SwiftUI
import Combine
import MapKit

// MARK: - Route summary model (align with RouteFavoritesStore)

public struct RouteMiniSummary: Equatable, Sendable {
    public let id: String                   // stable hash of geometry + options
    public let name: String                 // e.g., “Downtown → Plaza”
    public let distanceMeters: Double
    public let expectedTravelTime: TimeInterval
    public let polyline: MKPolyline         // light geometry for favorite/offline corridor planning
    public let createdAt: Date
    public init(id: String,
                name: String,
                distanceMeters: Double,
                expectedTravelTime: TimeInterval,
                polyline: MKPolyline,
                createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.distanceMeters = distanceMeters
        self.expectedTravelTime = expectedTravelTime
        self.polyline = polyline
        self.createdAt = createdAt
    }
}

// MARK: - DI seams

public protocol RouteFavoritesManaging: AnyObject {
    func isFavorited(routeId: String) -> Bool
    func save(_ summary: RouteMiniSummary) throws
    func remove(routeId: String) throws
    func setOfflineEnabled(_ on: Bool, routeId: String) throws
    func isOfflineEnabled(routeId: String) -> Bool
}

public protocol OfflineCorridorPrefetching: AnyObject {
    /// Start/resume a corridor prefetch for a route polyline and radius (meters).
    /// Progress ranges 0…1, delivered on main. Cancellation token must be honored.
    func prefetchCorridor(for routeId: String,
                          polyline: MKPolyline,
                          radiusMeters: Double,
                          priority: Float,
                          progress: @escaping (Double) -> Void) async throws
    /// Cancel any active prefetch for route id (idempotent).
    func cancelPrefetch(routeId: String)
    /// Returns true if corridor tiles are present and valid per manifest.
    func isCorridorReady(routeId: String) -> Bool
}

public protocol AnalyticsLogging {
    func log(_ event: AnalyticsEvent)
}
public struct AnalyticsEvent: Sendable, Hashable {
    public enum Category: String, Sendable { case favorites }
    public let name: String
    public let category: Category
    public let params: [String: AnalyticsValue]
    public init(name: String, category: Category, params: [String: AnalyticsValue]) {
        self.name = name; self.category = category; self.params = params
    }
}
public enum AnalyticsValue: Sendable, Hashable { case string(String), int(Int), bool(Bool), double(Double) }

// MARK: - ViewModel

@MainActor
public final class SaveRouteButtonViewModel: ObservableObject {
    @Published public private(set) var isSaved: Bool = false
    @Published public private(set) var isOfflineOn: Bool = false
    @Published public private(set) var prefetchProgress: Double = 0
    @Published public var infoMessage: String?
    @Published public var errorMessage: String?

    private let summary: RouteMiniSummary
    private let favorites: RouteFavoritesManaging
    private let tiles: OfflineCorridorPrefetching
    private let analytics: AnalyticsLogging?
    private var prefetchTask: Task<Void, Never>?
    private let corridorRadius: Double

    public init(summary: RouteMiniSummary,
                favorites: RouteFavoritesManaging,
                tiles: OfflineCorridorPrefetching,
                analytics: AnalyticsLogging? = nil,
                corridorRadius: Double = 80 /* meters */) {
        self.summary = summary
        self.favorites = favorites
        self.tiles = tiles
        self.analytics = analytics
        self.corridorRadius = corridorRadius

        hydrate()
    }

    private func hydrate() {
        isSaved = favorites.isFavorited(routeId: summary.id)
        isOfflineOn = favorites.isOfflineEnabled(routeId: summary.id)
        if isOfflineOn && tiles.isCorridorReady(routeId: summary.id) {
            prefetchProgress = 1.0
        } else {
            prefetchProgress = 0.0
        }
    }

    public func toggleSaved() {
        if isSaved {
            // Removing also cancels offline prefetch and disables offline flag
            cancelPrefetch()
            do {
                try favorites.setOfflineEnabled(false, routeId: summary.id)
                try favorites.remove(routeId: summary.id)
                isSaved = false
                isOfflineOn = false
                prefetchProgress = 0
                analytics?.log(.init(name: "route_unsave", category: .favorites,
                                     params: ["id": .string(summary.id)]))
                announce(NSLocalizedString("Removed from favorites.", comment: "unsave"))
            } catch {
                errorMessage = NSLocalizedString("Couldn’t remove. Try later.", comment: "remove fail")
            }
        } else {
            do {
                try favorites.save(summary)
                isSaved = true
                analytics?.log(.init(name: "route_save", category: .favorites,
                                     params: ["id": .string(summary.id),
                                              "dist_m": .int(Int(summary.distanceMeters))]))
                announce(NSLocalizedString("Saved to favorites.", comment: "save"))
            } catch {
                errorMessage = NSLocalizedString("Couldn’t save route.", comment: "save fail")
            }
        }
    }

    public func toggleOffline() {
        guard isSaved else {
            infoMessage = NSLocalizedString("Save the route first to enable offline.", comment: "need save")
            return
        }
        let next = !isOfflineOn
        do {
            try favorites.setOfflineEnabled(next, routeId: summary.id)
            isOfflineOn = next
        } catch {
            errorMessage = NSLocalizedString("Couldn’t update offline setting.", comment: "toggle fail")
            return
        }

        if next {
            startPrefetch()
        } else {
            cancelPrefetch()
            prefetchProgress = 0
            analytics?.log(.init(name: "route_offline_off", category: .favorites,
                                 params: ["id": .string(summary.id)]))
            announce(NSLocalizedString("Offline disabled for this route.", comment: "offline off"))
        }
    }

    private func startPrefetch() {
        // Cancel any existing task first
        cancelPrefetch()
        prefetchProgress = tiles.isCorridorReady(routeId: summary.id) ? 1.0 : 0.0
        analytics?.log(.init(name: "route_offline_on", category: .favorites,
                             params: ["id": .string(summary.id),
                                      "radius_m": .int(Int(corridorRadius))]))

        prefetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await tiles.prefetchCorridor(
                    for: summary.id,
                    polyline: summary.polyline,
                    radiusMeters: corridorRadius,
                    priority: 0.6
                ) { prog in
                    Task { @MainActor in
                        self.prefetchProgress = prog
                    }
                }
                await MainActor.run {
                    self.prefetchProgress = 1.0
                    self.infoMessage = NSLocalizedString("Route is ready offline.", comment: "ready")
                    self.announce(NSLocalizedString("Offline pack ready.", comment: "ready VO"))
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = NSLocalizedString("Offline prefetch failed.", comment: "prefetch fail")
                    self.isOfflineOn = false
                    try? self.favorites.setOfflineEnabled(false, routeId: self.summary.id)
                    self.prefetchProgress = 0
                }
            }
        }
    }

    private func cancelPrefetch() {
        tiles.cancelPrefetch(routeId: summary.id)
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    private func announce(_ msg: String) {
        UIAccessibility.post(notification: .announcement, argument: msg)
    }
}

// MARK: - View

public struct SaveRouteButton: View {
    @ObservedObject private var vm: SaveRouteButtonViewModel
    private let showOfflineSwitch: Bool

    /// - Parameters:
    ///   - viewModel: Injected with AppDI (FavoritesStore + TileFetcher).
    ///   - showOfflineSwitch: When true, renders a small inline toggle below the button; also accessible via context menu.
    public init(viewModel: SaveRouteButtonViewModel, showOfflineSwitch: Bool = true) {
        self.vm = viewModel
        self.showOfflineSwitch = showOfflineSwitch
    }

    public var body: some View {
        VStack(spacing: 8) {
            Button(action: vm.toggleSaved) {
                HStack(spacing: 10) {
                    Image(systemName: vm.isSaved ? "bookmark.fill" : "bookmark")
                        .imageScale(.large)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NSLocalizedString("Save route", comment: "save"))
                            .font(.subheadline.weight(.semibold))
                        Text(vm.isSaved ? NSLocalizedString("Saved", comment: "saved") : NSLocalizedString("Not saved", comment: "not saved"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if vm.isOfflineOn {
                        progressPill
                    }
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            .tint(vm.isSaved ? .accentColor : .gray.opacity(0.35))
            .contextMenu { quickMenu }
            .accessibilityLabel(Text(NSLocalizedString("Save route", comment: "ax label")))
            .accessibilityValue(Text(vm.isSaved ? NSLocalizedString("Saved", comment: "") : NSLocalizedString("Not saved", comment: "")))
            .accessibilityHint(Text(NSLocalizedString("Double tap to toggle favorite.", comment: "")))
            .accessibilityIdentifier("save_route_button")

            if showOfflineSwitch {
                Toggle(isOn: Binding(get: { vm.isOfflineOn }, set: { _ in vm.toggleOffline() })) {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.slash")
                        Text(NSLocalizedString("Offline", comment: "offline"))
                        Spacer()
                        if vm.prefetchProgress > 0 && vm.prefetchProgress < 1 {
                            ProgressView(value: vm.prefetchProgress)
                                .frame(width: 80)
                                .accessibilityLabel(Text(NSLocalizedString("Prefetch progress", comment: "")))
                        } else if vm.prefetchProgress >= 1 {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                                .accessibilityLabel(Text(NSLocalizedString("Offline ready", comment: "")))
                        }
                    }
                }
                .toggleStyle(.switch)
                .disabled(!vm.isSaved)
                .frame(minHeight: 44)
                .accessibilityIdentifier("offline_toggle")
            }
        }
        .overlay(toasts)
    }

    // Tiny capsule indicating offline state/progress (fits inside button)
    private var progressPill: some View {
        HStack(spacing: 6) {
            if vm.prefetchProgress >= 1 {
                Image(systemName: "checkmark.seal.fill")
            } else if vm.prefetchProgress > 0 {
                ProgressView(value: vm.prefetchProgress)
                    .frame(width: 36)
            } else {
                Image(systemName: "arrow.down.circle")
            }
            Text(vm.prefetchProgress >= 1
                 ? NSLocalizedString("Offline", comment: "offline ready")
                 : NSLocalizedString("Prep", comment: "preparing"))
            .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.primary.opacity(0.08), in: Capsule())
        .accessibilityIdentifier("offline_pill")
    }

    // Context menu for quick actions while riding (no modal)
    @ViewBuilder
    private var quickMenu: some View {
        Button {
            vm.toggleSaved()
        } label: {
            Label(vm.isSaved ? NSLocalizedString("Remove favorite", comment: "") : NSLocalizedString("Save favorite", comment: ""),
                  systemImage: vm.isSaved ? "bookmark.slash" : "bookmark")
        }
        Divider()
        Button {
            vm.toggleOffline()
        } label: {
            Label(vm.isOfflineOn ? NSLocalizedString("Disable offline", comment: "") : NSLocalizedString("Enable offline", comment: ""),
                  systemImage: vm.isOfflineOn ? "wifi" : "wifi.slash")
        }
    }

    // Toasts

    @ViewBuilder
    private var toasts: some View {
        VStack {
            Spacer()
            if let msg = vm.errorMessage {
                toast(text: msg, system: "exclamationmark.triangle.fill", bg: .red)
                    .onAppear { autoDismiss { vm.errorMessage = nil } }
            } else if let info = vm.infoMessage {
                toast(text: info, system: "checkmark.seal.fill", bg: .green)
                    .onAppear { autoDismiss { vm.infoMessage = nil } }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .animation(.easeInOut, value: vm.errorMessage != nil || vm.infoMessage != nil)
    }

    private func toast(text: String, system: String, bg: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: system).imageScale(.large).accessibilityHidden(true)
            Text(text).font(.callout).multilineTextAlignment(.leading)
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(bg.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
        .foregroundColor(.white)
        .accessibilityLabel(Text(text))
    }

    private func autoDismiss(_ body: @escaping () -> Void) {
        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); await MainActor.run(body) }
    }
}

// MARK: - Convenience builder

public extension SaveRouteButton {
    static func make(summary: RouteMiniSummary,
                     favorites: RouteFavoritesManaging,
                     tiles: OfflineCorridorPrefetching,
                     analytics: AnalyticsLogging? = nil,
                     showOfflineSwitch: Bool = true,
                     corridorRadius: Double = 80) -> SaveRouteButton {
        SaveRouteButton(
            viewModel: .init(summary: summary,
                             favorites: favorites,
                             tiles: tiles,
                             analytics: analytics,
                             corridorRadius: corridorRadius),
            showOfflineSwitch: showOfflineSwitch
        )
    }
}

// MARK: - DEBUG fakes

#if DEBUG
private final class FavsFake: RouteFavoritesManaging {
    private var saved: Set<String> = []
    private var offline: Set<String> = []
    func isFavorited(routeId: String) -> Bool { saved.contains(routeId) }
    func save(_ summary: RouteMiniSummary) throws { saved.insert(summary.id) }
    func remove(routeId: String) throws { saved.remove(routeId); offline.remove(routeId) }
    func setOfflineEnabled(_ on: Bool, routeId: String) throws { if on { offline.insert(routeId) } else { offline.remove(routeId) } }
    func isOfflineEnabled(routeId: String) -> Bool { offline.contains(routeId) }
}

private final class TilesFake: OfflineCorridorPrefetching {
    private var ready: Set<String> = []
    func prefetchCorridor(for routeId: String, polyline: MKPolyline, radiusMeters: Double, priority: Float, progress: @escaping (Double) -> Void) async throws {
        // Simulate progress
        for step in 1...10 {
            try await Task.sleep(nanoseconds: 80_000_000)
            if Task.isCancelled { return }
            await MainActor.run { progress(Double(step) / 10.0) }
        }
        ready.insert(routeId)
    }
    func cancelPrefetch(routeId: String) { /* no-op */ }
    func isCorridorReady(routeId: String) -> Bool { ready.contains(routeId) }
}

private func samplePolyline() -> MKPolyline {
    let pts = [
        CLLocationCoordinate2D(latitude: 49.2827, longitude: -123.1207),
        CLLocationCoordinate2D(latitude: 49.2800, longitude: -123.1100),
        CLLocationCoordinate2D(latitude: 49.2750, longitude: -123.1000)
    ]
    return MKPolyline(coordinates: pts, count: pts.count)
}

struct SaveRouteButton_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 12) {
            SaveRouteButton.make(
                summary: .init(id: "r1", name: "Downtown Line", distanceMeters: 4200, expectedTravelTime: 900, polyline: samplePolyline()),
                favorites: FavsFake(),
                tiles: TilesFake(),
                showOfflineSwitch: true
            )
            .padding(.horizontal)

            SaveRouteButton.make(
                summary: .init(id: "r2", name: "Seawall Cruise", distanceMeters: 8800, expectedTravelTime: 2100, polyline: samplePolyline()),
                favorites: FavsFake(),
                tiles: TilesFake(),
                showOfflineSwitch: false
            )
            .padding(.horizontal)
        }
        .preferredColorScheme(.dark)
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
    }
}
#endif

// MARK: - Integration notes
// • Wire to Services/Favorites/RouteFavoritesStore for save/remove/offline flags using the same route id hashing as used here.
// • Prefetch via Services/Offline/TileFetcher.prefetchCorridor(routeId:polyline:radiusMeters:...) with exponential backoff inside the service.
// • Ensure TileFetcher writes into a scoped cache dir (e.g., /Offline/Routes/<routeId>) so `isCorridorReady` is reliable.
// • Place this button in Map HUD (near VoiceToggle); keep context menu for quick offline toggle while riding.
// • Analytics: log save/unsave/offline-on/off; never log polyline points or exact coordinates.

// MARK: - Test plan (unit/UI)
// Unit:
// 1) Toggle save: not saved → save() called; saved flag flips; unsave cancels prefetch and clears offline flag.
// 2) Toggle offline: requires saved; enabling calls prefetch; progress updates 0→1; disabling cancels and resets progress.
// 3) Failure paths: favorites errors show errorMessage; prefetch error rolls back offline flag.
// 4) Hydration: when offline tiles already present, prefetchProgress starts at 1.
// UI:
// • Accessibility reads “Save route, Saved/Not saved. Offline ready/preparing.”
// • Context menu exposes Save/Remove + Enable/Disable offline; Toggle exists disabled when not saved.
// • UITest identifiers: “save_route_button”, “offline_toggle”, “offline_pill”.
