import MapKit
import XCTest
@testable import SKATEROUTE

@MainActor
final class LiveAppDITests: XCTestCase {
    func testServicesAreInitialized() {
        let di = LiveAppDI()

        XCTAssertTrue(di.locationManager is LocationManagerService)
        XCTAssertTrue(di.matcher is Matcher)
        XCTAssertTrue(di.routeService is RouteService)
        XCTAssertTrue(di.routeOptionsReducer is RouteOptionsReducer)
        XCTAssertTrue(di.motionService is MotionRoughnessService)
    }

    func testMakeRoutePlannerViewModelUsesSharedOfflineState() {
        let di = LiveAppDI()
        let viewModel = di.makeRoutePlannerViewModel()

        XCTAssertEqual(viewModel.downloadState, di.offlineTileManager.currentState())
    }

    func testMakeRerouteControllerCreatesUniqueInstance() {
        let di = LiveAppDI()

        let first = di.makeRerouteController()
        let second = di.makeRerouteController()

        let firstID = ObjectIdentifier(first as AnyObject)
        let secondID = ObjectIdentifier(second as AnyObject)
        XCTAssertNotEqual(firstID, secondID, "Expected unique reroute controller instances")
    }
}
