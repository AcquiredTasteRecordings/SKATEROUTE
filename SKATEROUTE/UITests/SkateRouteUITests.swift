import XCTest

final class SkateRouteUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func test_AppLaunches_Smoke() {
        let app = XCUIApplication(); app.launchArguments += ["--uitest-smoke"]; app.launch(); XCTAssertEqual(app.state, .runningForeground)
    }

    func test_CommonIdentifiers_AreQueryable() {
        let app = XCUIApplication(); app.launch()
        let ids = ["sr_map_canvas", "sr_search_pill", "sr_fab_go", "sr_origin_chip", "sr_dest_chip", "sr_cta_start", "sr_nav_next_turn", "sr_hazard_submit", "sr_spots_cluster", "sr_feed_list", "sr_profile_header", "sr_paywall", "sr_ref_code", "sr_onb_page_0", "sr_inbox_list", "sr_settings_form"]
        var foundAny = false
        for id in ids { if app.descendants(matching: .any)[id].firstMatch.exists { foundAny = true; break } }
        XCTAssertTrue(foundAny, "Expected at least one known accessibilityIdentifier on launch.")
    }
}
