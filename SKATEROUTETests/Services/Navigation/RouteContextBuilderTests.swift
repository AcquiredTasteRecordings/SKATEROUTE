import XCTest
import MapKit
@testable import SKATEROUTE

final class RouteContextBuilderTests: XCTestCase {

    @MainActor
    func testInstructionIncludesStepTagsHints() async {
        let step = makeStep(
            instructions: "Turn left",
            coordinates: [
                CLLocationCoordinate2D(latitude: 48.0, longitude: -123.0),
                CLLocationCoordinate2D(latitude: 48.0005, longitude: -123.0005)
            ]
        )

        let provider = StubAttributesProvider(perStep: [
            StepTags(hasProtectedLane: true, surfaceRough: false, hazardCount: 2, surface: "concrete")
        ])

        let builder = RouteContextBuilder(attributes: provider, segments: SegmentStoreStub())
        let route = makeRoute(steps: [step])
        let summary = GradeSummary(
            totalDistanceMeters: 100,
            samples: 1,
            avgGradePercent: -1.0,
            maxUphillPercent: 3.0,
            maxDownhillPercent: -4.0,
            totalAscentMeters: 5,
            totalDescentMeters: 5,
            sampleDistanceMeters: 10,
            sampleGradesPercent: [],
            smoothedGradesPercent: []
        )

        let contexts = await builder.context(for: route, gradeSummary: summary)

        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(contexts.first?.instruction, "Turn left – Protected lane, Hazard ×2, Concrete")
    }

    @MainActor
    func testInstructionFallsBackToHintsWhenNoBaseInstruction() async {
        let step = makeStep(
            instructions: "",
            coordinates: [
                CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0),
                CLLocationCoordinate2D(latitude: 37.0004, longitude: -122.0004)
            ]
        )

        let provider = StubAttributesProvider(perStep: [
            StepTags(hasProtectedLane: false, hasPaintedLane: true, surfaceRough: true, hazardCount: 0, surface: nil)
        ])

        let builder = RouteContextBuilder(attributes: provider, segments: SegmentStoreStub())
        let route = makeRoute(steps: [step])
        let summary = GradeSummary(
            totalDistanceMeters: 100,
            samples: 1,
            avgGradePercent: 0,
            maxUphillPercent: 0,
            maxDownhillPercent: 0,
            totalAscentMeters: 0,
            totalDescentMeters: 0,
            sampleDistanceMeters: 10,
            sampleGradesPercent: [],
            smoothedGradesPercent: []
        )

        let contexts = await builder.context(for: route, gradeSummary: summary)

        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(contexts.first?.instruction, "Painted lane, Rough surface")
    }

    @MainActor
    func testCompositeAttributionMergesStepTags() async {
        let step = makeStep(
            instructions: "",
            coordinates: [
                CLLocationCoordinate2D(latitude: 40.0, longitude: -74.0),
                CLLocationCoordinate2D(latitude: 40.0006, longitude: -74.0006)
            ]
        )

        let highPriority = StubAttributesProvider(perStep: [
            StepTags(hasProtectedLane: true, surfaceRough: false, hazardCount: 1, surface: "asphalt")
        ])
        let fallback = StubAttributesProvider(perStep: [
            StepTags(hasProtectedLane: false, hasPaintedLane: true, surfaceRough: true, hazardCount: 3, surface: "concrete")
        ])

        let composite = CompositeAttributionProvider(providers: [highPriority, fallback])
        let merged = await composite.tags(for: [step])

        XCTAssertEqual(merged.count, 1)
        let tags = merged[0]
        XCTAssertTrue(tags.hasProtectedLane)
        XCTAssertTrue(tags.hasPaintedLane)
        XCTAssertTrue(tags.surfaceRough)
        XCTAssertEqual(tags.hazardCount, 3)
        XCTAssertEqual(tags.surface, "asphalt")
    }

    @MainActor
    func testStepScoreAppliesLaneTurnAndHazardAdjustments() async {
        let scorer = SkateRouteScorer()
        let neutralContext = SkateRouteScorer.StepContext()

        let (baseScore, baseBreakdown) = scorer.stepScore(
            roughnessRMS: 0,
            slopePenalty: 0,
            mode: .smoothest,
            context: neutralContext
        )

        XCTAssertEqual(baseScore, baseBreakdown.finalScore)

        let decoratedContext = SkateRouteScorer.StepContext(
            hasProtectedLane: false,
            hasPaintedLane: true,
            surfaceRough: false,
            hazardCount: 2,
            turnRadians: .pi / 2
        )

        let (adjusted, breakdown) = scorer.stepScore(
            roughnessRMS: 0,
            slopePenalty: 0,
            mode: .smoothest,
            context: decoratedContext
        )

        let expectedLaneBoost = 1.0 + 0.10 * decoratedContext.laneBonus
        let expectedTurnFactor = 1.0 - 0.35 * decoratedContext.turnPenalty
        let expectedHazardFactor = 1.0 - 0.40 * decoratedContext.hazardPenalty
        let expectedScore = min(1.0, baseScore * expectedLaneBoost * expectedTurnFactor * expectedHazardFactor)

        XCTAssertEqual(adjusted, expectedScore, accuracy: 1e-6)
        XCTAssertEqual(breakdown.lanesFactor, expectedLaneBoost, accuracy: 1e-6)
        XCTAssertEqual(breakdown.turnFactor, expectedTurnFactor, accuracy: 1e-6)
        XCTAssertEqual(breakdown.hazardFactor, expectedHazardFactor, accuracy: 1e-6)
    }

    // MARK: - Helpers

    private func makeRoute(steps: [MKRoute.Step]) -> MKRoute {
        let route = MKRoute()
        route.setValue(steps, forKey: "steps")
        route.setValue(makePolyline(for: steps), forKey: "polyline")
        route.setValue(steps.reduce(0) { $0 + $1.distance }, forKey: "distance")
        return route
    }

    private func makePolyline(for steps: [MKRoute.Step]) -> MKPolyline {
        var coords: [CLLocationCoordinate2D] = []
        for step in steps {
            let polyline = step.polyline
            var stepCoords = [CLLocationCoordinate2D](repeating: .init(), count: polyline.pointCount)
            polyline.getCoordinates(&stepCoords, range: NSRange(location: 0, length: polyline.pointCount))
            coords.append(contentsOf: stepCoords)
        }
        return MKPolyline(coordinates: coords, count: coords.count)
    }

    private func makeStep(instructions: String, coordinates: [CLLocationCoordinate2D]) -> MKRoute.Step {
        let step = MKRoute.Step()
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        step.setValue(polyline, forKey: "polyline")
        step.setValue(instructions, forKey: "instructions")
        step.setValue(100.0, forKey: "distance")
        step.setValue(45.0, forKey: "expectedTravelTime")
        return step
    }
}

private actor StubAttributesProvider: StepAttributesProvider {
    private let perStep: [StepTags]

    init(perStep: [StepTags]) {
        self.perStep = perStep
    }

    func tags(for step: MKRoute.Step) async -> StepTags {
        perStep.first ?? StepTags()
    }

    func tags(for steps: [MKRoute.Step]) async -> [StepTags] {
        if perStep.count == steps.count {
            return perStep
        }
        if perStep.isEmpty {
            return Array(repeating: StepTags(), count: steps.count)
        }
        return steps.enumerated().map { index, _ in perStep[min(index, perStep.count - 1)] }
    }
}

private final class SegmentStoreStub: SegmentStoring {
    func makeStepId(route: MKRoute, stepIndex: Int) -> Int { stepIndex }
    func writeSegment(at stepIndex: Int, quality: Double, roughness: Double) {}
    func update(stepId: String, with roughnessRMS: Double) {}
    func clear() {}
    func readSegment(at stepIndex: Int) -> (quality: Double, roughness: Double, lastUpdated: Date, freshnessScore: Double)? { nil }
}

