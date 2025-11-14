import XCTest
@testable import SKATEROUTE

final class SkateRouteScorerStepTagsTests: XCTestCase {

    func testProtectedLaneAppliesFullBonus() {
        let tags = StepTags(hasProtectedLane: true, hazardCount: 0)
        let context = SkateRouteScorer.StepContext(tags: tags, turnRadians: 0)
        XCTAssertEqual(context.laneBonus, 1.0, accuracy: 0.0001)
        XCTAssertEqual(context.hazardPenalty, 0.0, accuracy: 0.0001)
    }

    func testPaintedLaneAppliesHalfBonus() {
        let tags = StepTags(hasPaintedLane: true, hazardCount: 0)
        let context = SkateRouteScorer.StepContext(tags: tags, turnRadians: 0)
        XCTAssertEqual(context.laneBonus, 0.5, accuracy: 0.0001)
    }

    func testHazardPenaltyRespondsToCount() {
        let safeTags = StepTags(hazardCount: 0)
        let riskyTags = StepTags(hazardCount: 3)
        let safe = SkateRouteScorer.StepContext(tags: safeTags, turnRadians: 0)
        let risky = SkateRouteScorer.StepContext(tags: riskyTags, turnRadians: 0)

        XCTAssertLessThan(safe.hazardPenalty, risky.hazardPenalty)
        XCTAssertEqual(safe.hazardPenalty, 0.0, accuracy: 0.0001)
        XCTAssertEqual(risky.hazardPenalty, 0.75, accuracy: 0.0001)
    }
}
