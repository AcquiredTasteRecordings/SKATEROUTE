// Services/ElevationService.swift
import Foundation
import CoreLocation
import MapKit

/// Provides elevation and slope/grade information using various elevation data sources.
/// Supports caching, adaptive smoothing, and thread-safe access to elevation data.
/// Elevation data can be sourced from SRTM, Terrain-RGB, or Municipal DEM datasets.
public final class ElevationService {
    /// Specifies the elevation data source in use.
    public let dataSource: String

    private let cache = NSCache<NSString, NSNumber>()
    private let cacheQueue = DispatchQueue(label: "com.elevationService.cacheQueue")
    private let fileManager = FileManager.default
    private let cacheDirectory: URL

    // Store recent elevation values per coordinate region for adaptive smoothing
    private var smoothingBuffers: [NSString: [Double]] = [:]
    private let smoothingWindowSize = 3

    /// Initializes the ElevationService with a specified data source.
    /// - Parameter dataSource: A string describing the elevation data source (e.g., "SRTM", "Terrain-RGB", "Municipal DEM").
    public init(dataSource: String = "Terrain-RGB") {
        self.dataSource = dataSource

        // Setup cache directory in app's caches folder
        if let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            cacheDirectory = cachesURL.appendingPathComponent("ElevationTiles", isDirectory: true)
            if !fileManager.fileExists(atPath: cacheDirectory.path) {
                try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: nil)
            }
        } else {
            // Fallback to temporary directory if caches directory not found
            cacheDirectory = fileManager.temporaryDirectory.appendingPathComponent("ElevationTiles", isDirectory: true)
            if !fileManager.fileExists(atPath: cacheDirectory.path) {
                try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: nil)
            }
        }
    }

    /// Fetches approximate elevation (in meters) for the given coordinate using the configured data source.
    /// This method uses caching with persistence and applies adaptive smoothing to results.
    /// - Parameter coordinate: The geographic coordinate to query.
    /// - Returns: The elevation in meters at the specified coordinate.
    /// - Throws: Propagates any errors encountered during data retrieval.
    public func elevation(at coordinate: CLLocationCoordinate2D) async throws -> Double {
        let keyString = "\(coordinate.latitude),\(coordinate.longitude)"
        let key = keyString as NSString

        // Thread-safe cache read
        if let cachedValue = cacheQueue.sync(execute: { cache.object(forKey: key) }) {
            // Apply smoothing on cached value if possible
            return cacheQueue.sync { smoothedElevation(forKey: key, newValue: cachedValue.doubleValue) }
        }

        // Attempt to load persisted elevation tile data
        if let persistedElevation = try? loadElevationFromDisk(forKey: keyString) {
            cacheQueue.sync {
                cache.setObject(NSNumber(value: persistedElevation), forKey: key)
            }
            return cacheQueue.sync { smoothedElevation(forKey: key, newValue: persistedElevation) }
        }

        // Simulate elevation data retrieval (stubbed model)
        // Replace with real DEM sampling logic as needed.
        let simulated = 40 + 15 * sin(coordinate.latitude * .pi / 180 * 10) * cos(coordinate.longitude * .pi / 180 * 10)

        // Persist and cache the result
        cacheQueue.sync {
            cache.setObject(NSNumber(value: simulated), forKey: key)
            appendElevationToSmoothingBuffer(forKey: key, value: simulated)
        }
        try? saveElevationToDisk(simulated, forKey: keyString)

        return cacheQueue.sync { smoothedElevation(forKey: key, newValue: simulated) }
    }

    /// Returns slope (grade %) between two coordinates.
    /// Also logs whether the segment is uphill, downhill, or flat for debugging purposes.
    /// - Parameters:
    ///   - a: Start coordinate.
    ///   - b: End coordinate.
    /// - Returns: Grade as a percentage.
    /// - Throws: Propagates any errors from elevation queries.
    public func grade(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) async throws -> Double {
        let ea = try await elevation(at: a)
        let eb = try await elevation(at: b)
        let dist = CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        guard dist > 0 else { return 0 }

        let gradePercent = ((eb - ea) / dist) * 100.0

        // Log slope direction for debugging
        let slopeDescription: String
        if gradePercent > 0.1 {
            slopeDescription = "uphill"
        } else if gradePercent < -0.1 {
            slopeDescription = "downhill"
        } else {
            slopeDescription = "flat"
        }
        print("Grade segment from (\(a.latitude),\(a.longitude)) to (\(b.latitude),\(b.longitude)) is \(slopeDescription) with grade \(gradePercent)%")

        return gradePercent
    }

    // MARK: - Private Helper Methods

    /// Saves elevation value to disk cache for persistence.
    private func saveElevationToDisk(_ elevation: Double, forKey key: String) throws {
        let fileURL = cacheDirectory.appendingPathComponent(key.replacingOccurrences(of: ",", with: "_") + ".txt")
        let elevationString = String(elevation)
        try elevationString.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Loads elevation value from disk cache if available.
    private func loadElevationFromDisk(forKey key: String) throws -> Double? {
        let fileURL = cacheDirectory.appendingPathComponent(key.replacingOccurrences(of: ",", with: "_") + ".txt")
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        return Double(content)
    }

    /// Updates smoothing buffer with new elevation value and returns the rolling average.
    private func smoothedElevation(forKey key: NSString, newValue: Double) -> Double {
        appendElevationToSmoothingBuffer(forKey: key, value: newValue)
        let buffer = smoothingBuffers[key] ?? []
        guard !buffer.isEmpty else { return newValue }
        let average = buffer.reduce(0, +) / Double(buffer.count)
        return average
    }

    /// Appends a new elevation value to the smoothing buffer for the given key,
    /// maintaining the buffer size within the smoothing window.
    private func appendElevationToSmoothingBuffer(forKey key: NSString, value: Double) {
        var buffer = smoothingBuffers[key] ?? []
        buffer.append(value)
        if buffer.count > smoothingWindowSize {
            buffer.removeFirst()
        }
        smoothingBuffers[key] = buffer
    }
}

public struct GradeSummary {
    public let maxGrade: Double   // absolute max uphill or downhill in %
    public let meanGrade: Double  // average signed grade in %
    public let brakingMask: [Bool] // per-step flags
    public let slopePenalty: Double // 0..1 normalized penalty for scoring
}

public extension ElevationService {
    /// Samples grades per route step and returns a slope summary used by the scorer and renderer.
    /// - Parameters:
    ///   - route: The MKRoute object containing route steps.
    ///   - sampleMeters: Distance interval for sampling grades along each step (default 75 meters).
    /// - Returns: A GradeSummary containing max grade, mean grade, braking mask, and slope penalty.
    func summarizeGrades(on route: MKRoute, sampleMeters: Double = 75) async -> GradeSummary {
        let steps = route.steps
        var grades: [Double] = []
        var brakingMask = [Bool](repeating: false, count: steps.count)

        for (i, step) in steps.enumerated() where step.distance > 0 {
            let coords = step.polyline.coordinates()
            guard coords.count >= 2 else { continue }
            // Use first/last coordinate as a coarse sample
            let a = coords.first!, b = coords.last!
            let g = (try? await grade(from: a, to: b)) ?? 0
            grades.append(g)
            if g < -6 { brakingMask[i] = true }
        }

        let mean = grades.isEmpty ? 0 : grades.reduce(0,+) / Double(grades.count)
        let maxAbs = grades.map { abs($0) }.max() ?? 0
        // Normalize slope penalty: no penalty <= 3%, full penalty >= 12%
        let slopePenalty = max(0, min(1, (maxAbs - 3) / (12 - 3)))
        return GradeSummary(maxGrade: maxAbs, meanGrade: mean, brakingMask: brakingMask, slopePenalty: slopePenalty)
    }
}
