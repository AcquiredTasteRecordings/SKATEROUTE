// Core/AppCoordinator.swift
import SwiftUI
import CoreLocation

@MainActor
public final class AppCoordinator: ObservableObject {
    @Published public var router: AppRouter = .home

    private let dependencies: any AppDependencyContainer

    public init(dependencies: any AppDependencyContainer) {
        self.dependencies = dependencies
    }

    public func makeRootView() -> AnyView {
        switch router {
        case .home:
            return AnyView(HomeView(dependencies: dependencies))
        case let .map(src, dst, mode):
            return AnyView(
                MapScreen(source: src,
                          destination: dst,
                          mode: mode,
                          dependencies: dependencies) { [weak self] in
                    self?.dismissToHome()
                }
            )
        }
    }

    public func presentMap(from source: CLLocationCoordinate2D,
                           to destination: CLLocationCoordinate2D,
                           mode: RideMode) {
        router = .map(source: source, destination: destination, mode: mode)
    }

    public func dismissToHome() {
        router = .home
    }
}
