import XCTest
import StoreKit
@testable import SKATEROUTE

final class ReceiptValidatorTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        UserDefaults(suiteName: Self.testSuiteName)?.removePersistentDomain(forName: Self.testSuiteName)
    }

    func testRefreshEntitlementsRecognizesMonthlySKU() async {
        await assertPremiumRecognition(
            productID: "com.skateroute.pro.monthly",
            expectedPlan: .subscriptionMonthly,
            subscriptionUnit: .month
        )
    }

    func testRefreshEntitlementsRecognizesYearlySKU() async {
        await assertPremiumRecognition(
            productID: "com.skateroute.pro.yearly",
            expectedPlan: .subscriptionYearly,
            subscriptionUnit: .year
        )
    }

    func testMigratesLegacyCacheKeyToNewProductIdentifiers() throws {
        let defaults = UserDefaults(suiteName: Self.testSuiteName)!
        defaults.removePersistentDomain(forName: Self.testSuiteName)

        let now = Date()
        let legacyStatus = PremiumStatus(
            isPremiumActive: true,
            activePlan: .subscriptionMonthly,
            activeProductID: "skateroute.premium.monthly",
            expirationDate: now.addingTimeInterval(7200),
            willAutoRenew: true,
            lastChecked: now
        )

        let encoder = JSONEncoder()
        let legacyData = try encoder.encode(legacyStatus)
        defaults.set(legacyData, forKey: "premium.status.cache.skateroute.premium.monthly")

        let validator = ReceiptValidator(
            userDefaults: defaults,
            entitlementsProvider: { [] },
            autoRefreshOnInit: false
        )

        XCTAssertEqual(validator.status.activeProductID, "com.skateroute.pro.monthly")
        XCTAssertTrue(validator.status.isPremiumActive)
        XCTAssertNotNil(defaults.data(forKey: "premium.status.cache"))
        XCTAssertNil(defaults.data(forKey: "premium.status.cache.skateroute.premium.monthly"))
    }

    // MARK: - Helpers

    private func assertPremiumRecognition(
        productID: String,
        expectedPlan: PremiumPlanKind,
        subscriptionUnit: Product.SubscriptionPeriod.Unit?,
        file: StaticString = #fileID,
        line: UInt = #line
    ) async {
        let defaults = UserDefaults(suiteName: Self.testSuiteName)!
        defaults.removePersistentDomain(forName: Self.testSuiteName)

        let now = Date()
        let snapshot = ReceiptValidator.EntitlementSnapshot(
            productID: productID,
            purchaseDate: now.addingTimeInterval(-3600),
            expirationDate: now.addingTimeInterval(3600),
            revocationDate: nil,
            isUpgraded: false,
            subscriptionPeriodUnit: subscriptionUnit
        )

        let validator = ReceiptValidator(
            cacheKey: "test.premium.status",
            userDefaults: defaults,
            entitlementsProvider: { [snapshot] },
            autoRefreshOnInit: false
        )

        await validator.refreshEntitlements()

        XCTAssertTrue(validator.isPremiumActive, file: file, line: line)
        XCTAssertEqual(validator.status.activeProductID, productID, file: file, line: line)
        XCTAssertEqual(validator.status.activePlan, expectedPlan, file: file, line: line)
    }

    private static let testSuiteName = "ReceiptValidatorTests"
}
