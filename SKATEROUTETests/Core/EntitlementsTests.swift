import XCTest
@testable import SKATEROUTE

final class EntitlementsTests: XCTestCase {

    func testOfflinePacksUnlocksOfflineFeature() {
        XCTAssertEqual(ProductID.offlinePacks.rawValue, "com.skateroute.pro.offline")
        XCTAssertEqual(ProductID.offlinePacks.unlocks, [.offlinePacks])
    }

    func testAdvancedAnalyticsUnlocksAnalyticsFeature() {
        XCTAssertEqual(ProductID.advancedAnalytics.rawValue, "com.skateroute.pro.analytics")
        XCTAssertEqual(ProductID.advancedAnalytics.unlocks, [.advancedAnalytics])
    }

    func testProEditorUnlocksEditorFeature() {
        XCTAssertEqual(ProductID.proEditor.rawValue, "com.skateroute.pro.editor")
        XCTAssertEqual(ProductID.proEditor.unlocks, [.proEditor])
    }

    func testAllProductIdentifiersAreUnique() {
        let identifiers = ProductID.allCases.map(\.rawValue)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }
}
