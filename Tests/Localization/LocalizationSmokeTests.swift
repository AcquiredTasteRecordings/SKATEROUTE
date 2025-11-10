#if canImport(XCTest)
import XCTest
final class LocalizationSmokeTests: XCTestCase {
    func testCriticalKeysExist() {
        let keys = [
            "nav.cue.turn_left","nav.cue.turn_right","nav.cue.keep_straight",
            "paywall.title","paywall.button.buy","paywall.button.restore",
            "map.overlay.legend.smooth","map.overlay.legend.rough"
        ]
        for k in keys {
            let v = NSLocalizedString(k, comment: "")
            XCTAssertNotEqual(v, k, "Missing localization: \(k)")
        }
    }
}
#endif
