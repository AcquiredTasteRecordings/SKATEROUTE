import XCTest
import MapKit
@testable import SKATEROUTE

@MainActor
final class LiveAppDITests: XCTestCase {
    func testLiveAppDIInitializesDependencies() {
        XCTAssertNoThrow({ _ = LiveAppDI() }())
        let container = LiveAppDI()

        XCTAssertTrue(container.routeContextBuilder is RouteContextBuilder)
        XCTAssertNotNil(container.routeService as? RouteService)
        XCTAssertNotNil(container.motionService as? MotionRoughnessService)
    }

    func testRouteContextBuilderProducesContext() async {
        let container = LiveAppDI()
        let builder = container.routeContextBuilder

        let coords: [CLLocationCoordinate2D] = [
            CLLocationCoordinate2D(latitude: 48.4284, longitude: -123.3656),
            CLLocationCoordinate2D(latitude: 48.4285, longitude: -123.3646)
        ]
        let polyline = MKPolyline(coordinates: coords, count: coords.count)

        let step = MKRoute.Step()
        step.setValue(polyline, forKey: "polyline")
        step.setValue(polyline.distanceMetersFallback(), forKey: "distance")
        step.setValue(30.0, forKey: "expectedTravelTime")
        step.setValue("Test step", forKey: "instructions")

        let route = MKRoute()
        route.setValue(polyline, forKey: "polyline")
        route.setValue([step], forKey: "steps")
        route.setValue(polyline.distanceMetersFallback(), forKey: "distance")
        route.setValue(30.0, forKey: "expectedTravelTime")

        let summary = GradeSummary(
            totalDistanceMeters: polyline.distanceMetersFallback(),
            samples: 1,
            avgGradePercent: 0,
            maxUphillPercent: 0,
            maxDownhillPercent: 0,
            totalAscentMeters: 0,
            totalDescentMeters: 0,
            sampleDistanceMeters: polyline.distanceMetersFallback(),
            sampleGradesPercent: [],
            smoothedGradesPercent: []
        )

        let contexts = await builder.context(for: route, gradeSummary: summary)
        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(contexts.first?.index, 0)
        XCTAssertEqual(contexts.first?.instruction, "Test step")
    }
}

private extension MKPolyline {
    func distanceMetersFallback() -> CLLocationDistance {
        var distance: CLLocationDistance = 0
        var previous: MKMapPoint?
        for coordinate in coordinates() {
            let point = MKMapPoint(coordinate)
            if let previous {
                distance += MKMetersBetweenMapPoints(previous, point)
            }
            previous = point
        }
        return distance
    }

    func coordinates() -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}
