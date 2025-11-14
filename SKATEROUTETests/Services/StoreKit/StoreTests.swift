import XCTest
@testable import SKATEROUTE

#if DEBUG
@MainActor
final class StoreTests: XCTestCase {
    private var analytics: AnalyticsLoggerSpy!
    private var entitlements: EntitlementsFake!
    private var store: StoreFake!

    override func setUp() {
        super.setUp()
        analytics = AnalyticsLoggerSpy()
        entitlements = EntitlementsFake(granted: [])
        store = StoreFake(entitlements: entitlements, analytics: analytics)
    }

    override func tearDown() {
        store = nil
        entitlements = nil
        analytics = nil
        #if DEBUG
        StoreTestOverrides.reset()
        #endif
        super.tearDown()
    }

    func testProductUnavailablePathsSurfaceUxErrorAndAnalytics() async {
        #if DEBUG
        StoreTestOverrides.fetchProducts = { _ in [] }
        #endif

        store.purchase(.offlinePacks)

        await waitFor { self.store.lastError != nil }

        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(store.lastError?.message, AppError.productUnavailable.errorDescription)
        XCTAssertTrue(analytics.events.contains(where: { event in
            event.name == "purchase_failed" && event.params["product"] == .string(ProductID.offlinePacks.rawValue)
        }))
    }

    func testPurchaseFailureLogsAnalyticsWithUnderlyingAppError() async {
        #if DEBUG
        StoreTestOverrides.fetchProducts = { _ in throw AppError.purchaseNotAllowed }
        #endif

        store.purchase(.advancedAnalytics)

        await waitFor { self.store.lastError != nil }

        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(store.lastError?.message, AppError.purchaseNotAllowed.errorDescription)
        XCTAssertTrue(analytics.events.contains(where: { event in
            event.name == "purchase_failed" && event.params["product"] == .string(ProductID.advancedAnalytics.rawValue)
        }))
    }

    // MARK: - Helpers

    private func waitFor(timeout: TimeInterval = 1.0, condition: @escaping @Sendable () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
#endif
