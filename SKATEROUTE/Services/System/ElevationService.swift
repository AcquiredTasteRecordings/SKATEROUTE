// Services/ElevationService.swift
// Route elevation + grade analytics with clean DI and graceful fallbacks.
// - Resamples route polyline at fixed intervals
// - Queries an injectable elevation source (DEM or stub)
// - Computes ascent/descent and grade stats with smoothing
// - Falls back to neutral metrics if elevation is unavailable

import Foundation
import CoreLocation
import MapKit

// MARK: - Public Models

/// Aggregate grade/elevation summary for a route.
/// Fields used by downstream code are preserved; extras are additive and optional.
public struct GradeSummary: Sendable {
    public let totalDistanceMeters: CLLocationDistance
    public let samples: Int

    // Route-level aggregates (percent grade, +/-)
    public let avgGradePercent: Double
    public let maxUphillPercent: Double
    public let maxDownhillPercent: Double

    // Elevation gain/loss (meters).
    public let totalAscentMeters: Double
    public let totalDescentMeters: Double

    // Optional richer diagnostics
    public let sampleDistanceMeters: Double
    public let sampleGradesPercent: [Double] // per-segment grade (%), length ~ samples-1
    public let smoothedGradesPercent: [Double] // EMA-smoothed grades, same length

    public init(
        totalDistanceMeters: CLLocationDistance,
        samples: Int,
        avgGradePercent: Double,
        maxUphillPercent: Double,
        maxDownhillPercent: Double,
        totalAscentMeters: Double,
        totalDescentMeters: Double,
        sampleDistanceMeters: Double,
        sampleGradesPercent: [Double],
        smoothedGradesPercent: [Double]
    ) {
        self.totalDistanceMeters = totalDistanceMeters
        self.samples = samples
        self.avgGradePercent = avgGradePercent
        self.maxUphillPercent = maxUphillPercent
        self.maxDownhillPercent = maxDownhillPercent
        self.totalAscentMeters = totalAscentMeters
        self.totalDescentMeters = totalDescentMeters
        self.sampleDistanceMeters = sampleDistanceMeters
        self.sampleGradesPercent = sampleGradesPercent
        self.smoothedGradesPercent = smoothedGradesPercent
    }

    /// Convenience factory for a neutral summary (no elevation data available)
    public static func neutral(for route: MKRoute, samples: Int, sampleDistance: Double) -> GradeSummary {
        GradeSummary(
            totalDistanceMeters: route.distance,
            samples: samples,
            avgGradePercent: 0,
            maxUphillPercent: 0,
            maxDownhillPercent: 0,
            totalAscentMeters: 0,
            totalDescentMeters: 0,
            sampleDistanceMeters: sampleDistance,
            sampleGradesPercent: [],
            smoothedGradesPercent: []
        )
    }
}

// MARK: - Data Source (injectable)

/// Protocol a DEM provider should implement.
/// Return altitude in meters relative to mean sea level. If unavailable, return nil.
public protocol ElevationDataSource: Sendable {
    func elevation(at coordinate: CLLocationCoordinate2D) async -> Double?
}

/// Default null data source: always returns nil (neutral fallback).
public struct NullElevationSource: ElevationDataSource {
    public init() {}
    public func elevation(at coordinate: CLLocationCoordinate2D) async -> Double? { nil }
}

// MARK: - Service

public final class ElevationService: ElevationServing {

    // Smoothing + counting knobs
    private let elevationSource: ElevationDataSource
    private let emaAlpha: Double = 0.35            // exponential moving average smoothing
    private let minDeltaForGain: Double = 0.75     // meters; ignore tiny noise
    private let maxReasonableGradePct: Double = 60 // clamp to drop outliers

    public init(source: ElevationDataSource = NullElevationSource()) {
        self.elevationSource = source
    }

    public func warmUpIfNeeded() async {
        // No preparatory work is necessary yet; placeholder for future DEM priming.
    }

    /// Summarize grades along a route. If elevation cannot be fetched, returns a neutral summary.
    public func summarizeGrades(on route: MKRoute, sampleMeters: Double) async -> GradeSummary {
        // Build a resampled polyline at ~sampleMeters spacing
        let coords = route.polyline.coordinates()
        guard coords.count >= 2 else {
            return GradeSummary.neutral(for: route, samples: 1, sampleDistance: sampleMeters)
        }

        let targetSpacing = max(5.0, sampleMeters) // never lower than 5 m to avoid oversampling noise
        let sampledCoords = resamplePolyline(coords, spacing: targetSpacing)
        let samplesCount = max(1, sampledCoords.count)

        // Query elevations; if any return non-nil, we consider elevation "available".
        // We cap concurrency to avoid thread explosions.
        let elevations = await queryElevations(sampledCoords, maxConcurrent: 8)
        let hasElevation = elevations.contains(where: { $0 != nil })

        guard hasElevation, elevations.count == sampledCoords.count else {
            return GradeSummary.neutral(for: route, samples: samplesCount, sampleDistance: targetSpacing)
        }

        // Fill missing with nearest-known neighbor to keep continuity.
        let filledElevs = fillMissingElevations(elevations)

        // Compute per-segment grades and ascent/descent.
        var gradesPct: [Double] = []
        gradesPct.reserveCapacity(max(0, samplesCount - 1))

        var totalAscent = 0.0
        var totalDescent = 0.0

        for i in 0..<(samplesCount - 1) {
            let dz = filledElevs[i + 1] - filledElevs[i]
            let dxy = MKMetersBetweenMapPoints(MKMapPoint(sampledCoords[i]), MKMapPoint(sampledCoords[i + 1]))
            guard dxy > 0.1 else {
                gradesPct.append(0)
                continue
            }
            var pct = (dz / dxy) * 100.0
            // Clamp unreasonable outliers (bad elevations or degenerate geometry)
            pct = min(max(pct, -maxReasonableGradePct), maxReasonableGradePct)
            gradesPct.append(pct)

            if dz >= minDeltaForGain { totalAscent += dz }
            if dz <= -minDeltaForGain { totalDescent += -dz }
        }

        // Smooth grades to reduce jitter
        let smoothed = ema(gradesPct, alpha: emaAlpha)

        // Aggregate stats
        let avg = smoothed.isEmpty ? 0 : smoothed.reduce(0, +) / Double(smoothed.count)
        let maxUp = smoothed.max() ?? 0
        let maxDown = smoothed.min() ?? 0

        return GradeSummary(
            totalDistanceMeters: route.distance,
            samples: samplesCount,
            avgGradePercent: avg,
            maxUphillPercent: maxUp,
            maxDownhillPercent: maxDown,
            totalAscentMeters: totalAscent,
            totalDescentMeters: totalDescent,
            sampleDistanceMeters: targetSpacing,
            sampleGradesPercent: gradesPct,
            smoothedGradesPercent: smoothed
        )
    }

    // MARK: - Elevation Queries

    private func queryElevations(_ coords: [CLLocationCoordinate2D], maxConcurrent: Int) async -> [Double?] {
        guard !coords.isEmpty else { return [] }
        var out = Array<Double?>(repeating: nil, count: coords.count)
        // Simple bounded concurrency
        await withTaskGroup(of: (Int, Double?).self) { group in
            var i = 0
            // Prime up to maxConcurrent tasks
            let initial = min(maxConcurrent, coords.count)
            while i < initial {
                let idx = i
                let c = coords[idx]
                group.addTask { [source = elevationSource] in
                    (idx, await source.elevation(at: c))
                }
                i += 1
            }
            // For each completion, enqueue the next
            while let (idx, value) = await group.next() {
                out[idx] = value
                if i < coords.count {
                    let nextIdx = i
                    let c = coords[nextIdx]
                    group.addTask { [source = elevationSource] in
                        (nextIdx, await source.elevation(at: c))
                    }
                    i += 1
                }
            }
        }
        return out
    }

    // MARK: - Utilities

    private func ema(_ series: [Double], alpha: Double) -> [Double] {
        guard !series.isEmpty else { return [] }
        var out = series
        for i in 1..<series.count {
            out[i] = alpha * series[i] + (1 - alpha) * out[i - 1]
        }
        return out
    }

    private func fillMissingElevations(_ elevs: [Double?]) -> [Double] {
        // Forward fill then backward fill to handle leading/trailing nils.
        var out = elevs
        // Forward
        var last: Double? = nil
        for i in 0..<out.count {
            if let v = out[i] { last = v }
            else if let l = last { out[i] = l }
        }
        // Backward
        var next: Double? = nil
        for i in stride(from: out.count - 1, through: 0, by: -1) {
            if let v = out[i] { next = v }
            else if let n = next { out[i] = n }
        }
        // Replace any remaining with zeros (shouldn’t happen if at least one non-nil exists)
        return out.map { $0 ?? 0 }
    }

    /// Resample a polyline to points spaced by `spacing` meters (including first and last).
    private func resamplePolyline(_ coords: [CLLocationCoordinate2D], spacing: Double) -> [CLLocationCoordinate2D] {
        guard coords.count >= 2 else { return coords }
        var result: [CLLocationCoordinate2D] = []
        result.reserveCapacity(Int((MKPolyline.approxLength(coords) / spacing).rounded()) + 2)

        var carry = 0.0
        for i in 0..<(coords.count - 1) {
            let a = coords[i], b = coords[i + 1]
            let segLen = MKMetersBetweenMapPoints(MKMapPoint(a), MKMapPoint(b))
            if result.isEmpty { result.append(a) }
            if segLen <= 0.01 { continue }

            var remaining = segLen
            var tStart = carry / segLen
            while remaining + carry >= spacing {
                let t = tStart + (spacing / segLen)
                let p = lerp(a, b, t: t)
                result.append(p)
                remaining -= spacing
                tStart = t
                carry = 0
            }
            carry += remaining
        }
        // Ensure last coordinate is present
        if let last = coords.last, result.last?.latitude != last.latitude || result.last?.longitude != last.longitude {
            result.append(last)
        }
        return result
    }

    private func lerp(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, t: Double) -> CLLocationCoordinate2D {
        let clampedT = max(0, min(1, t))
        let lat = a.latitude + (b.latitude - a.latitude) * clampedT
        let lon = a.longitude + (b.longitude - a.longitude) * clampedT
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

// MARK: - Polyline helpers

private extension MKPolyline {
    func coordinates() -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }

    static func approxLength(_ coords: [CLLocationCoordinate2D]) -> CLLocationDistance {
        guard coords.count > 1 else { return 0 }
        var total: CLLocationDistance = 0
        for i in 0..<(coords.count - 1) {
            total += MKMetersBetweenMapPoints(MKMapPoint(coords[i]), MKMapPoint(coords[i + 1]))
        }
        return total
    }
}


