// Core/AppCoordinator.swift
// SkateRoute
//
// Responsibilities:
// - Owns current high-level route (AppRouter) and navigation path
// - Provides a SwiftUI root view that renders the active screen
// - Handles scene lifecycle + deep link routing with safe parsing
// - Stays DI-friendly without hard-coding services (minimal surface now)
// - No secrets, no entitlements assumptions; compile-safe today


import SwiftUI
import Combine
import CoreLocation

// Minimal router enum to resolve missing type and case references.
public enum AppRouter: Hashable {
    case home
    case map(source: CLLocationCoordinate2D, destination: CLLocationCoordinate2D)
}

// Manual Equatable/Hashable because CLLocationCoordinate2D is not Hashable by default.
public extension AppRouter {
    static func == (lhs: AppRouter, rhs: AppRouter) -> Bool {
        switch (lhs, rhs) {
        case (.home, .home):
            return true
        case let (.map(ls, ld), .map(rs, rd)):
            return ls.latitude == rs.latitude &&
                   ls.longitude == rs.longitude &&
                   ld.latitude == rd.latitude &&
                   ld.longitude == rd.longitude
        default:
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .home:
            hasher.combine(0)
        case let .map(source, destination):
            hasher.combine(1)
            hasher.combine(source.latitude)
            hasher.combine(source.longitude)
            hasher.combine(destination.latitude)
            hasher.combine(destination.longitude)
        }
    }
}

@MainActor
public final class AppCoordinator: ObservableObject {
    // MARK: - Published navigation state
    @Published public private(set) var route: AppRouter = .home
    @Published public var navPath = NavigationPath() // reserved for in-flow pushes

    // MARK: - Inputs (kept optional for compile-safety; we’ll inject concrete instances as we wire steps)
    public struct Hooks {
        // Lifecycle hooks — safe to set later
        var onBecomeActive: (() -> Void)?
        var onEnterBackground: (() -> Void)?
        var onOpenURL: ((URL) -> Void)?
        public init(
            onBecomeActive: (() -> Void)? = nil,
            onEnterBackground: (() -> Void)? = nil,
            onOpenURL: ((URL) -> Void)? = nil
        ) {
            self.onBecomeActive = onBecomeActive
            self.onEnterBackground = onEnterBackground
            self.onOpenURL = onOpenURL
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private let hooks: Hooks
    let dependencies: AppDependencyContainer

    // MARK: - Init
    public init(dependencies: AppDependencyContainer, hooks: Hooks = .init()) {
        self.dependencies = dependencies
        self.hooks = hooks
    }

    // MARK: - Commands (safe, minimal surface)
    public func start() {
        // Placeholder for future boot logic (e.g., session restore, remote config)
        // Kept synchronous to avoid startup jank.
        route = .home
    }

    public func goHome(resetStack: Bool = true) {
        if resetStack { navPath = NavigationPath() }
        route = .home
    }

    public func goToMap(source: CLLocationCoordinate2D, destination: CLLocationCoordinate2D, resetStack: Bool = true) {
        if resetStack { navPath = NavigationPath() }
        route = .map(source: source, destination: destination)
    }

    public func presentMap(from source: CLLocationCoordinate2D?, to destination: CLLocationCoordinate2D, mode: RideMode) {
        if let src = source {
            goToMap(source: src, destination: destination)
        } else {
            // If no source, just go to map with destination. The map view model can handle
            // finding current location if needed.
            goToMap(source: destination, destination: destination) // Placeholder, actual logic depends on MapScreen VM
        }
    }

    public func dismissToHome() {
        goHome()
    }

    // MARK: - Deep Link Handling
    // Accepts URLs like:
    // skateroute://map?src=49.2827,-123.1207&dst=49.2756,-123.1236
    // skateroute://home
    public func handle(url: URL) {
        hooks.onOpenURL?(url)

        guard url.scheme?.lowercased() == "skateroute" else { return }
        let host = (url.host ?? "").lowercased()

        if host == "home" {
            goHome()
            return
        }

        if host == "map" {
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let q = comps?.queryItems ?? []
            guard
                let src = q.first(where: { $0.name == "src" })?.value,
                let dst = q.first(where: { $0.name == "dst" })?.value,
                let srcCoord = Self.parseLatLon(src),
                let dstCoord = Self.parseLatLon(dst)
            else {
                // Malformed? Fail-safe to home, do not crash.
                goHome()
                return
            }
            goToMap(source: srcCoord, destination: dstCoord)
            return
        }

        // Unknown host — ignore gracefully.
    }

    // MARK: - Scene lifecycle
    public func onScenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            hooks.onBecomeActive?()
        case .background:
            hooks.onEnterBackground?()
        default:
            break
        }
    }
}

// MARK: - Coordinator Root View
public struct CoordinatorView: View {
    @StateObject private var coordinator: AppCoordinator
    @Environment(\.scenePhase) private var scenePhase

    public init(coordinator: AppCoordinator) {
        _coordinator = StateObject(wrappedValue: coordinator)
    }

    public var body: some View {
        // Single NavigationStack for push flows inside the current route.
        NavigationStack(path: $coordinator.navPath) {
            content
                .onOpenURL { url in
                    coordinator.handle(url: url)
                }
                .onChange(of: scenePhase) { newPhase in
                    coordinator.onScenePhaseChanged(newPhase)
                }
                // Keeps future global overlays (toasts, banners) composable
        }
        .environmentObject(coordinator)
        // Keep navigation bars consistent; per-screen overrides will win
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.route {
        case .home:
            // HomeView exists in repo; we keep direct call to avoid extra wrappers.
            HomeView(dependencies: coordinator.dependencies)
                .id("home-root") // ensures a clean refresh if we switch away/back

        case let .map(source, destination):
            // MapScreen expects coordinates; we maintain clear data flow.
            MapScreen(source: source, destination: destination)
                .id("map-\(source.latitude),\(source.longitude)->\(destination.latitude),\(destination.longitude)")
        }
    }
}

// MARK: - View Factory
public extension AppCoordinator {
    func makeRootView() -> some View {
        CoordinatorView(coordinator: self)
    }
}

// MARK: - Push routing
extension AppCoordinator: AppRouting {
    public func handleNotification(userInfo: [AnyHashable: Any]) {
        // Minimal mapping for hazard/spot notifications. Extend as payloads evolve.
        if let lat = userInfo["lat"] as? Double,
           let lon = userInfo["lon"] as? Double {
            let destination = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            let source = dependencies.locationManager.currentLocation?.coordinate
            let mode = RideModeStore.load()
            presentMap(from: source, to: destination, mode: mode)
            return
        }

        if let payload = userInfo["route"] as? [String: Double],
           let lat = payload["lat"],
           let lon = payload["lon"] {
            let destination = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            let source = dependencies.locationManager.currentLocation?.coordinate
            let mode = RideModeStore.load()
            presentMap(from: source, to: destination, mode: mode)
            return
        }

        // Default: surface the home screen.
        goHome()
    }
}

// MARK: - Helpers
private extension AppCoordinator {
    static func parseLatLon(_ raw: String) -> CLLocationCoordinate2D? {
        // Accept "lat,lon" or "lat%2Clon". Trim spaces and guard ranges.
        let parts = raw
            .replacingOccurrences(of: "%2C", with: ",")
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else { return nil }
        guard (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}


