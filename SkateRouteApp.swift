// SkateRouteApp.swift
// Bootstraps DI, coordinator, lifecycle budgets, and deep-link routing.
// Consistent with LiveAppDI, AppCoordinator, AccuracyProfile, and privacy posture.

import SwiftUI
import CoreLocation
import SwiftData
import OSLog

@main
struct SkateRouteApp: App {
    // MARK: - Dependencies / Coordinator
    @StateObject private var dependencies: LiveAppDI
    @StateObject private var coordinator: AppCoordinator

    // MARK: - Environment
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Logging
    private let log = Logger(subsystem: "com.yourcompany.skateroute", category: "app")

    init() {
        let container = LiveAppDI()
        _dependencies = StateObject(wrappedValue: container)
        _coordinator  = StateObject(wrappedValue: AppCoordinator(dependencies: container))

        // Lightweight launch analytics (no third-party tracking).
        let bundle = Bundle.main
        let version = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        let build   = (bundle.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
        log.info("App launched \(version) (\(build)) at \(Date().timeIntervalSince1970, privacy: .public)")
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                coordinator.makeRootView()
            }
            .environmentObject(coordinator)
            .environmentObject(dependencies)
            .tint(.accentColor)
            .onOpenURL(perform: handle(url:))
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb, perform: handle(userActivity:))
            .task(priority: .utility) {
                // Housekeeping on cold start
                await dependencies.locationManager.applyPowerBudgetForMonitoring()
                await dependencies.routeService.warmUpIfNeeded()
                await dependencies.elevationService.warmUpIfNeeded()
            }
            .onChange(of: scenePhase) { _, phase in
                // Power budgets aligned with lifecycle
                switch phase {
                case .active:
                    dependencies.locationManager.applyAccuracy(.balanced)
                case .inactive:
                    // Keep it light; keep geofences alive for drift signals
                    dependencies.locationManager.applyAccuracy(.monitoring)
                case .background:
                    dependencies.locationManager.applyAccuracy(.background)
                @unknown default:
                    dependencies.locationManager.applyAccuracy(.monitoring)
                }
            }
        }
        // SwiftData model container (local community content)
        .modelContainer(for: [SurfaceRating.self])
    }
}

// MARK: - Deep Link Routing

private extension SkateRouteApp {
    func handle(url: URL) {
        // Accepts:
        //  skateroute://navigate?src=lat,lon&dst=lat,lon&mode=smoothest
        //  skateroute://map?dst=lat,lon  (from share sheet)
        //  https(s)://…/navigate?src=…&dst=… (universal link hand-off)
        guard let host = url.host?.lowercased() else {
            Logger(subsystem: "com.yourcompany.skateroute", category: "deeplink")
                .debug("Deep link host missing: \(url.absoluteString, privacy: .public)")
            return
        }

        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let params = Self.query(q)
        switch host {
        case "navigate", "map":
            if let dst = Self.parseCoord(params["dst"]) {
                let src = Self.parseCoord(params["src"]) ?? dependencies.locationManager.currentLocation?.coordinate
                let mode = Self.parseMode(params["mode"]) ?? RideModeStore.load()
                if let from = src {
                    coordinator.presentMap(from: from, to: dst, mode: mode.coarseRoutingIntent == .smoothest ? .smoothest : .fastMildRoughness)
                } else {
                    // No source yet; present home and let VM grab current location.
                    coordinator.dismissToHome()
                }
            } else {
                Logger(subsystem: "com.yourcompany.skateroute", category: "deeplink")
                    .warning("Deep link missing dst param: \(url.absoluteString, privacy: .public)")
            }
        default:
            // Future: session/spot/profile routes
            Logger(subsystem: "com.yourcompany.skateroute", category: "deeplink")
                .debug("Unhandled deep link host \(host, privacy: .public)")
        }
    }

    func handle(userActivity: NSUserActivity) {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else { return }
        handle(url: url)
    }

    // MARK: - Parse helpers

    static func query(_ comps: URLComponents?) -> [String: String] {
        guard let items = comps?.queryItems else { return [:] }
        var dict: [String: String] = [:]
        for item in items { if let v = item.value { dict[item.name] = v } }
        return dict
    }

    static func parseCoord(_ raw: String?) -> CLLocationCoordinate2D? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ",").map { String($0) }
        guard parts.count == 2,
              let lat = Double(parts[0]), let lon = Double(parts[1]),
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    static func parseMode(_ raw: String?) -> RideMode? {
        guard let raw, let mode = RideMode(rawValue: raw) else { return nil }
        return mode
    }
}


