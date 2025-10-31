// Core/AppCoordinator.swift
import SwiftUI
import CoreLocation

@MainActor
public final class AppCoordinator: ObservableObject {
    @Published public var router: AppRouter = .home

    public init() {}

    @ViewBuilder
    public func makeRootView() -> some View {
        switch router {
        case .home:
            // Home needs to be able to push to .map
            HomeView()
                .environmentObject(self)

        case .map(let src, let dst, let mode):
            // MapScreen gets a "done" closure to pop back
            MapScreen(source: src,
                      destination: dst,
                      mode: mode) { [weak self] in
                self?.router = .home
            }
        }
    }
}
