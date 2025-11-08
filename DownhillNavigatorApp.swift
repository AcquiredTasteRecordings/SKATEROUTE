// DownhillNavigatorApp.swift
import SwiftUI
import os

@main
struct DownhillNavigatorApp: App {
    @StateObject private var dependencies: LiveAppDI
    @StateObject private var coordinator: AppCoordinator

    init() {
        let container = LiveAppDI()
        _dependencies = StateObject(wrappedValue: container)
        _coordinator = StateObject(wrappedValue: AppCoordinator(dependencies: container))
        let logger = Logger(subsystem: "com.skateroute.app", category: "analytics")
        logger.info("App launched at \(Date().formatted(.iso8601))")
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                coordinator.makeRootView()
            }
            .environmentObject(coordinator)
            .environmentObject(dependencies)
            .onOpenURL { url in
                coordinator.handleDeepLink(url)
            }
        }
        .modelContainer(for: [SurfaceRating.self])
    }
}
extension AppCoordinator {
    func handleDeepLink(_ url: URL) {
        // TODO: route to map / session / spot
        print("Deep link received (not implemented): \(url)")
    }
}
