import XCTest
@testable import SKATEROUTE

final class RouteContextBuilderInstructionTests: XCTestCase {
    func testProtectedLaneAndHazardsAppendedToBaseInstruction() {
        let tags = StepTags(hasProtectedLane: true, hazardCount: 2)
        let instruction = RouteContextBuilder.composeInstruction(base: "Turn right", tags: tags)
        XCTAssertEqual(instruction, "Turn right – Protected lane, Hazard ×2")
    }

    func testHintsEmittedWhenBaseInstructionMissing() {
        let tags = StepTags(hasPaintedLane: true, hazardCount: 1)
        let instruction = RouteContextBuilder.composeInstruction(base: nil, tags: tags)
        XCTAssertEqual(instruction, "Painted lane, Hazard ×1")
    }

    func testNoHintsKeepsOriginalInstruction() {
        let instruction = RouteContextBuilder.composeInstruction(base: "Bear left", tags: .neutral)
        XCTAssertEqual(instruction, "Bear left")
    }
}
