import XCTest
@testable import SKATEROUTE

final class AppCoordinatorSpotsTests: XCTestCase {
    func testPresentSpotCreatePushesDestination() {
        let di = LiveAppDI()
        let coordinator = AppCoordinator(dependencies: di)
        coordinator.goHome()
        XCTAssertEqual(coordinator.navPath.count, 0)

        coordinator.presentSpotCreate()

        XCTAssertEqual(coordinator.navPath.count, 1)
    }

    func testDismissSpotCreatePopsDestination() {
        let di = LiveAppDI()
        let coordinator = AppCoordinator(dependencies: di)
        coordinator.presentSpotCreate()
        XCTAssertEqual(coordinator.navPath.count, 1)

        coordinator.dismissSpotCreate()

        XCTAssertEqual(coordinator.navPath.count, 0)
    }
}
