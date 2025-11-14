// Features/Community/ViewModels/QuickReportViewModel.swift
import Foundation
import CoreLocation
import SwiftData

@MainActor
struct QuickReportViewModel {
    private let modelContext: ModelContext
    private let precision: Int

    init(modelContext: ModelContext, precision: Int = 4) {
        self.modelContext = modelContext
        self.precision = precision
    }

    /// Saves or updates a SurfaceRating near the given coordinate using a small quantized bin.
    @discardableResult
    func upsertRating(at coordinate: CLLocationCoordinate2D, value: SurfaceValue) throws -> SurfaceRating {
        let (qlat, qlon) = quantize(coordinate)
        let eps = pow(10.0, Double(-precision)) / 2.0 // half-step window

        let predicate = #Predicate<SurfaceRating> {
            ($0.latitude >= qlat - eps) && ($0.latitude <= qlat + eps) &&
            ($0.longitude >= qlon - eps) && ($0.longitude <= qlon + eps)
        }

        let descriptor = FetchDescriptor<SurfaceRating>(
            predicate: predicate,
            sortBy: [.init(\.updatedAt, order: .reverse)]
        )

        let existing = try? modelContext.fetch(descriptor).first
        let rating: SurfaceRating

        if let existing {
            rating = existing.updateValue(value)
        } else {
            let newRating = SurfaceRating(coordinate: coordinate, value: value)
            modelContext.insert(newRating)
            rating = newRating
        }

        try modelContext.save()
        return rating
    }

    private func quantize(_ coordinate: CLLocationCoordinate2D) -> (Double, Double) {
        let p = pow(10.0, Double(precision))
        let lat = (coordinate.latitude * p).rounded() / p
        let lon = (coordinate.longitude * p).rounded() / p
        return (lat, lon)
    }
}
