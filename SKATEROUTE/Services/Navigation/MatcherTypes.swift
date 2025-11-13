// Services/MatcherTypes.swift
// Value-first types shared by Matcher, RideRecorder, and TurnCueEngine.
// Lightweight, Sendable-friendly models with clear semantics and zero MapKit dependency.

import Foundation
import CoreLocation

// MARK: - Sample captured from sensors

/// Atomic input sample for the matcher pipeline.
/// Keep this tiny: it gets copied frequently and traverses actor boundaries.
public struct MatchSample: @unchecked Sendable, Equatable {
    /// Original CLLocation from LocationManagerService (speed, course, accuracy live here).
    public let location: CLLocation

    /// Unitless vibration estimate from MotionRoughnessService (RMS, higher = rougher).
    public let roughnessRMS: Double

    /// Capture time. Explicit so windows/orderings are deterministic across threads.
    public let timestamp: Date

    // MARK: Derived (cheap)

    public var coordinate: CLLocationCoordinate2D { location.coordinate }
    public var speedMps: Double { max(0, location.speed) }                // -1 → 0
    public var speedKmh: Double { speedMps * 3.6 }
    public var courseDegrees: Double? { location.course >= 0 ? location.course : nil }
    public var horizontalAccuracy: CLLocationAccuracy { location.horizontalAccuracy }

    // MARK: Init

    /// Designated initializer.
    public init(location: CLLocation, roughnessRMS: Double, timestamp: Date = Date()) {
        self.location = location
        self.roughnessRMS = max(0, roughnessRMS)
        self.timestamp = timestamp
    }

    /// Convenience initializer from a coordinate (timestamp = now).
    public init(coordinate: CLLocationCoordinate2D, roughnessRMS: Double, timestamp: Date = Date()) {
        self.init(
            location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
            roughnessRMS: roughnessRMS,
            timestamp: timestamp
        )
    }
}

// MARK: - Match results (matcher → consumers)

/// Coarse quality buckets for match confidence.
/// Comparable so callers can write `if quality >= .good { … }`.
public enum AlignmentQuality: Int, Comparable, Sendable {
    case poor = 0     // likely wrong: far from step/polyline, bad accuracy
    case fair = 1     // usable but jittery; treat with caution
    case good = 2     // solid alignment
    case excellent = 3 // very tight lock (near polyline with stable heading)

    public static func < (lhs: AlignmentQuality, rhs: AlignmentQuality) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Output emitted by the matcher after snapping a `MatchSample` to a route “step”.
/// Keeps indices/metrics, not heavy MapKit types, to remain Sendable-friendly and cheap.
public struct MatchResult: Sendable, Equatable {
    /// Route step index we believe the rider is on (0-based).
    public let stepIndex: Int

    /// Progress along the *current* step, 0…1 (best-effort). Consumers should clamp.
    public let progressInStep: Double

    /// Remaining distance to the *start of the next maneuver* (meters), best-effort.
    public let distanceToNextManeuver: CLLocationDistance

    /// Snapped coordinate on the step geometry (best-effort projection).
    public let snappedCoordinate: CLLocationCoordinate2D

    /// Confidence bucket for quick downstream decisions.
    public let quality: AlignmentQuality

    /// Smoothed rider speed (km/h) calculated by the matcher, if available.
    public let speedKmh: Double?

    /// Source sample timestamp for temporal ordering.
    public let timestamp: Date

    public init(stepIndex: Int,
                progressInStep: Double,
                distanceToNextManeuver: CLLocationDistance,
                snappedCoordinate: CLLocationCoordinate2D,
                quality: AlignmentQuality,
                speedKmh: Double?,
                timestamp: Date) {
        self.stepIndex = max(0, stepIndex)
        self.progressInStep = progressInStep.clamped01()
        self.distanceToNextManeuver = max(0, distanceToNextManeuver)
        self.snappedCoordinate = snappedCoordinate
        self.quality = quality
        self.speedKmh = speedKmh.map { max(0, $0) }
        self.timestamp = timestamp
    }
}

// MARK: - Sliding window (optional helper for roughness/speed smoothing)

/// Small fixed-size window of samples for smoothing or quality heuristics.
/// Designed to be created/updated inside an actor for thread safety.
public struct MatchWindow: Sendable, Equatable {
    public private(set) var samples: [MatchSample] = []
    public let capacity: Int

    public init(capacity: Int = 8) {
        self.capacity = max(1, capacity)
    }

    public var isFull: Bool { samples.count >= capacity }
    public var isEmpty: Bool { samples.isEmpty }

    public var startTime: Date? { samples.first?.timestamp }
    public var endTime: Date? { samples.last?.timestamp }

    public var avgSpeedKmh: Double {
        guard !samples.isEmpty else { return 0 }
        let s = samples.reduce(0.0) { $0 + $1.speedKmh }
        return s / Double(samples.count)
    }

    public var avgRoughness: Double {
        guard !samples.isEmpty else { return 0 }
        let s = samples.reduce(0.0) { $0 + $1.roughnessRMS }
        return s / Double(samples.count)
    }

    /// Append a sample; evict the oldest if over capacity.
    public mutating func push(_ sample: MatchSample) {
        samples.append(sample)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    /// Drop all samples.
    public mutating func reset() { samples.removeAll(keepingCapacity: true) }
}

// MARK: - Sugar

private extension Double {
    func clamped01() -> Double { max(0, min(1, self)) }
}


