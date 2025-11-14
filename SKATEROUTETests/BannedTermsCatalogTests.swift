import XCTest
@testable import SKATEROUTE

final class BannedTermsCatalogTests: XCTestCase {
    func testEnglishCatalogLoadsAndIsSanitized() {
        let terms = BannedTermsCatalog.terms(for: Locale(identifier: "en"))
        XCTAssertFalse(terms.isEmpty, "English banned list should not be empty")
        XCTAssertTrue(terms.allSatisfy { $0 == $0.lowercased() }, "Terms should be lowercase for comparisons")
        XCTAssertEqual(terms.count, Set(terms).count, "Terms should be unique")
    }

    func testSpanishCatalogLoads() {
        let terms = BannedTermsCatalog.terms(for: Locale(identifier: "es"))
        XCTAssertFalse(terms.isEmpty, "Spanish banned list should not be empty")
    }

    func testFallbackToEnglishWhenLocaleMissing() {
        let terms = BannedTermsCatalog.terms(for: Locale(identifier: "zz"))
        XCTAssertFalse(terms.isEmpty, "Fallback to English should provide coverage")
        let english = BannedTermsCatalog.terms(for: Locale(identifier: "en"))
        XCTAssertEqual(terms, english, "Unknown locales fall back to English set")
    }
}
