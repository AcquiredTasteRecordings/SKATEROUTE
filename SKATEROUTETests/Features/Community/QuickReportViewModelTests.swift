import XCTest
import SwiftData
import CoreLocation
@testable import SKATEROUTE

@MainActor
final class QuickReportViewModelTests: XCTestCase {
    func testUpsertRatingPersistsSurfaceRating() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SurfaceRating.self, configurations: config)
        let context = ModelContext(container)
        let viewModel = QuickReportViewModel(modelContext: context)

        let coordinate = CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)
        let value: SurfaceValue = .butter

        let saved = try viewModel.upsertRating(at: coordinate, value: value)

        XCTAssertEqual(saved.valueEnum, value)
        XCTAssertEqual(saved.latitude, coordinate.latitude, accuracy: 0.000001)
        XCTAssertEqual(saved.longitude, coordinate.longitude, accuracy: 0.000001)

        let fetch = FetchDescriptor<SurfaceRating>()
        let results = try context.fetch(fetch)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, saved.id)
        XCTAssertEqual(results.first?.valueEnum, value)
    }
}
