import XCTest
@testable import SKATEROUTE

final class ErrorsTests: XCTestCase {
    func testUXErrorFromProductUnavailableProvidesBannerCopy() {
        let uxError = UXError.from(.productUnavailable)
        let expectedMessage = NSLocalizedString("That product isn’t available right now.", comment: "error")
        XCTAssertEqual(uxError.message, expectedMessage)
        XCTAssertEqual(uxError.title, NSLocalizedString("Store Unavailable", comment: "title"))
        XCTAssertEqual(uxError.recovery, NSLocalizedString("Try again later or choose a different product.", comment: "suggestion"))
    }
}
