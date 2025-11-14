import XCTest
import Combine
@testable import SKATEROUTE

@MainActor
final class VideoVisibilityMonitorTests: XCTestCase {
    func testVisibilityThresholdPublishesChanges() throws {
        let monitor = VideoVisibilityMonitor(threshold: 0.6)
        let container = CGRect(x: 0, y: 0, width: 200, height: 200)
        var received: [Bool] = []
        let expectation = expectation(description: "visibility updates")

        let cancellable = monitor.$isVisibleEnough
            .dropFirst() // skip initial false
            .sink { value in
                received.append(value)
                if received.count == 2 { expectation.fulfill() }
            }

        monitor.update(containerFrame: container, contentFrame: container)
        // Offset enough to fall below threshold (25% visible)
        let mostlyHidden = CGRect(x: 0, y: 150, width: 200, height: 200)
        monitor.update(containerFrame: container, contentFrame: mostlyHidden)

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(received, [true, false])
        cancellable.cancel()
    }

    func testMarkHiddenResetsVisibility() {
        let monitor = VideoVisibilityMonitor(threshold: 0.5)
        let container = CGRect(x: 0, y: 0, width: 100, height: 100)
        monitor.update(containerFrame: container, contentFrame: container)
        XCTAssertTrue(monitor.isVisibleEnough)

        monitor.markHidden()
        XCTAssertFalse(monitor.isVisibleEnough)
    }
}
