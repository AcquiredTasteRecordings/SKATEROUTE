import CoreLocation
import MapKit
import SwiftUI
import XCTest
@testable import SKATEROUTE

@MainActor
final class AppCoordinatorTests: XCTestCase {
    func testPresentMapUpdatesRouter() {
        let dependencies = LiveAppDI()
        let coordinator = AppCoordinator(dependencies: dependencies)
        let source = CLLocationCoordinate2D(latitude: 37.3317, longitude: -122.0307)
        let destination = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)

        coordinator.presentMap(from: source, to: destination, mode: .smoothest)

        guard case let .map(src, dst, mode) = coordinator.router else {
            XCTFail("Expected map route")
            return
        }

        XCTAssertEqual(src.latitude, source.latitude, accuracy: 1e-6)
        XCTAssertEqual(dst.longitude, destination.longitude, accuracy: 1e-6)
        XCTAssertEqual(mode, .smoothest)
    }

    func testDismissToHomeResetsRouter() {
        let dependencies = LiveAppDI()
        let coordinator = AppCoordinator(dependencies: dependencies)
        let source = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let destination = CLLocationCoordinate2D(latitude: 1, longitude: 1)

        coordinator.presentMap(from: source, to: destination, mode: .smoothest)
        coordinator.dismissToHome()

        XCTAssertEqual(coordinator.router, .home)
    }

    func testMakeRootViewProvidesAnyView() {
        let dependencies = LiveAppDI()
        let coordinator = AppCoordinator(dependencies: dependencies)

        let view = coordinator.makeRootView()
        XCTAssertTrue(view is AnyView)
    }
}
