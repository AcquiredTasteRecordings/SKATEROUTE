import XCTest

final class CommentsFlowUITests: XCTestCase {
    func testScrollAndReportFlowAutoDismissesToast() {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-UITestScenario", "comments_report"])
        app.launch()

        let commentsList = app.otherElements["comments_list"]
        XCTAssertTrue(commentsList.waitForExistence(timeout: 5), "Comments list did not appear")

        let distantRow = app.otherElements["comment_row_uitest-comment-15"]
        commentsList.swipeUp()
        XCTAssertTrue(distantRow.waitForExistence(timeout: 5), "Expected distant comment after scrolling")

        let targetRow = app.otherElements["comment_row_uitest-report-target"]
        XCTAssertTrue(targetRow.waitForExistence(timeout: 2), "Report target row missing")
        targetRow.press(forDuration: 0.8)

        let reportButton = app.buttons["Report"]
        XCTAssertTrue(reportButton.waitForExistence(timeout: 2), "Context menu report action missing")
        reportButton.tap()

        let submitButton = app.buttons["Submit Report"]
        XCTAssertTrue(submitButton.waitForExistence(timeout: 2), "Report sheet submit button missing")
        submitButton.tap()

        let toast = app.otherElements["comments_toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 3), "Report success toast did not appear")
        XCTAssertTrue(toast.waitForNonExistence(timeout: 5), "Report success toast did not auto-dismiss")
    }
}

private extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }
}
