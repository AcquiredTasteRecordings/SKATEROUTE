// Tests/AppCoordinatorTests.swift
import XCTest
import SwiftUI
import MapKit
import CoreLocation
import Combine
@testable import SKATEROUTE

@MainActor
final class AppCoordinatorTests: XCTestCase {

    private var dependencies: LiveAppDI!
    private var coordinator: AppCoordinator!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() async throws {
        try await super.setUp()
        dependencies = LiveAppDI()
        coordinator = AppCoordinator(dependencies: dependencies)
        cancellables = []
    }

    override func tearDown() async throws {
        cancellables = nil
        coordinator = nil
        dependencies = nil
        try await super.tearDown()
    }

    // MARK: - Router basics

    func testInitialRouterIsHome() {
        XCTAssertEqual(coordinator.route, .home)
    }

    func testPresentMapUpdatesRouterExactly() {
        let src = CLLocationCoordinate2D(latitude: 37.3317, longitude: -122.0307)
        let dst = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)

        coordinator.presentMap(from: src, to: dst, mode: .smoothest)

        guard case let .map(a, b) = coordinator.route else {
            return XCTFail("Expected .map after presentMap")
        }

        XCTAssertEqual(a.latitude, src.latitude, accuracy: 1e-6)
        XCTAssertEqual(a.longitude, src.longitude, accuracy: 1e-6)
        XCTAssertEqual(b.latitude, dst.latitude, accuracy: 1e-6)
        XCTAssertEqual(b.longitude, dst.longitude, accuracy: 1e-6)
    }

    func testDismissToHomeResetsRouter() {
        let src = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let dst = CLLocationCoordinate2D(latitude: 1, longitude: 1)

        coordinator.presentMap(from: src, to: dst, mode: .smoothest)
        coordinator.dismissToHome()

        XCTAssertEqual(coordinator.route, .home)
    }

    func testDismissToHomeIsIdempotent() {
        coordinator.dismissToHome()
        XCTAssertEqual(coordinator.route, .home)

        // Call again to ensure no crashes or state glitches.
        coordinator.dismissToHome()
        XCTAssertEqual(coordinator.route, .home)
    }

    // MARK: - Publishing semantics

    func testRouterPublishesOnPresentAndDismiss() {
        let published = expectation(description: "router published twice")
        published.expectedFulfillmentCount = 2

        coordinator.objectWillChange
            .sink { _ in published.fulfill() }
            .store(in: &cancellables)

        let src = CLLocationCoordinate2D(latitude: 49.2827, longitude: -123.1207)
        let dst = CLLocationCoordinate2D(latitude: 48.4284, longitude: -123.3656)

        coordinator.presentMap(from: src, to: dst, mode: .fastMildRoughness)
        coordinator.dismissToHome()

        wait(for: [published], timeout: 1.0)
        XCTAssertEqual(coordinator.route, .home)
    }

    // MARK: - Determinism checks

    func testPresentMapDeterministicForSameInputs() {
        let aSrc = CLLocationCoordinate2D(latitude: 40.0, longitude: -74.0)
        let aDst = CLLocationCoordinate2D(latitude: 40.1, longitude: -74.1)

        coordinator.presentMap(from: aSrc, to: aDst, mode: .nightSafe)
        let first = coordinator.route

        // Present the same again → router should equal the same value (no drift)
        coordinator.presentMap(from: aSrc, to: aDst, mode: .nightSafe)
        let second = coordinator.route

        XCTAssertEqual(first, second)
    }

    // MARK: - Safety rails

    func testPresentMapOnMainThread() {
        // The coordinator is @MainActor; calling from here should be safe.
        let src = CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12)
        let dst = CLLocationCoordinate2D(latitude: 51.51, longitude: -0.11)
        coordinator.presentMap(from: src, to: dst, mode: .smoothest)
        XCTAssertTrue(Thread.isMainThread, "Coordinator mutations must occur on main.")
    }

    // MARK: - Helpers (none needed beyond Combine expectation)
}
