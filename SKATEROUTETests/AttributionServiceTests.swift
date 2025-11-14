import XCTest
@testable import SKATEROUTE

final class AttributionServiceTests: XCTestCase {
    func testCompositeMergeRespectsPriorityAndAggregatesMetadata() {
        let primary = StepTags(
            hasProtectedLane: false,
            hasPaintedLane: true,
            surfaceRough: false,
            hazardCount: 1,
            highwayClass: "primary",
            surface: "asphalt",
            metadata: ["source": "remote"]
        )

        let secondary = StepTags(
            hasProtectedLane: true,
            hasPaintedLane: false,
            surfaceRough: true,
            hazardCount: 3,
            highwayClass: "residential",
            surface: "concrete",
            metadata: ["freshnessDays": "3"]
        )

        let merged = CompositeAttributionProvider.merge(primary, secondary)

        XCTAssertTrue(merged.hasProtectedLane)
        XCTAssertTrue(merged.hasPaintedLane)
        XCTAssertTrue(merged.surfaceRough)
        XCTAssertEqual(merged.hazardCount, 3)
        XCTAssertEqual(merged.highwayClass, "primary")
        XCTAssertEqual(merged.surface, "asphalt")
        XCTAssertEqual(merged.metadata["source"], "remote")
        XCTAssertEqual(merged.metadata["freshnessDays"], "3")
    }
}

final class StepContextBridgeTests: XCTestCase {
    func testBridgeCopiesLaneHazardFlags() {
        let tags = StepTags(
            hasProtectedLane: true,
            hasPaintedLane: false,
            surfaceRough: true,
            hazardCount: 2
        )

        let ctx = SkateRouteScorer.StepContext(tags: tags, turnRadians: .pi / 2)

        XCTAssertTrue(ctx.hasProtectedLane)
        XCTAssertFalse(ctx.hasPaintedLane)
        XCTAssertTrue(ctx.surfaceRough)
        XCTAssertEqual(ctx.hazardCount, 2)
        XCTAssertEqual(ctx.turnRadians, .pi / 2, accuracy: 1e-6)
    }
}
