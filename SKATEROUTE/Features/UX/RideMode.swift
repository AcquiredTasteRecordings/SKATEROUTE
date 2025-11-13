// Features/UX/RideMode.swift
// Rider-facing presets that steer routing + UX defaults.
// Localized, Codable, Sendable, and decoupled (no MapKit dependency).
// Each mode exposes human labels, icon, bias, and a RouteTuning bundle
// that upstream services (RouteOptionsReducer, RouteContextBuilder) can consume.

import Foundation

/// Compact, serializable preferences the routing layer can apply per mode.
/// Keep this independent of MapKit so it’s easy to test and persist.
public struct RouteTuning: Codable, Sendable, Equatable {
    /// Favor smoother geometry and known “butter” segments. 0…1 (higher favors smooth).
    public let smoothnessWeight: Double
    /// Penalize steep segments. Max allowed grade (%). `nil` = no hard cap.
    public let maxGradePercent: Double?
    /// Penalize or avoid stairs segments entirely.
    public let avoidStairs: Bool
    /// Penalize roads with higher speed limits / heavy traffic adjacency.
    public let avoidHighSpeedTraffic: Bool
    /// Increase penalty for crossings / frequent stop events. 0…1 (higher = fewer crossings).
    public let crossingsPenaltyWeight: Double
    /// Prefer lit/prominent corridors at night. 0…1 (higher = stronger preference).
    public let nightLightingPreference: Double
    /// Cap expected travel speed (km/h). `nil` = let the engine infer from context.
    public let speedCapKmh: Double?
    /// Weight for sidewalks / multi-use paths vs. mixed road segments. 0…1.
    public let pathPreference: Double
    /// Prefer known skate spots POIs along the route. 0…1 (used by trick crawl).
    public let trickSpotAttraction: Double

    public init(
        smoothnessWeight: Double,
        maxGradePercent: Double?,
        avoidStairs: Bool,
        avoidHighSpeedTraffic: Bool,
        crossingsPenaltyWeight: Double,
        nightLightingPreference: Double,
        speedCapKmh: Double?,
        pathPreference: Double,
        trickSpotAttraction: Double
    ) {
        self.smoothnessWeight = clamp01(smoothnessWeight)
        self.maxGradePercent = maxGradePercent
        self.avoidStairs = avoidStairs
        self.avoidHighSpeedTraffic = avoidHighSpeedTraffic
        self.crossingsPenaltyWeight = clamp01(crossingsPenaltyWeight)
        self.nightLightingPreference = clamp01(nightLightingPreference)
        self.speedCapKmh = speedCapKmh
        self.pathPreference = clamp01(pathPreference)
        self.trickSpotAttraction = clamp01(trickSpotAttraction)
    }
}

@inline(__always) private func clamp01(_ v: Double) -> Double { max(0, min(1, v)) }

/// Rider modes exposed in the UI. Backed by strings for stable persistence.
public enum RideMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case smoothest
    case chillFewCrossings
    case fastMildRoughness
    case trickSpotCrawl
    case nightSafe

    public var id: String { rawValue }

    /// Small bias applied to composite scoring (positive favors higher smoothness).
    public var bias: Double {
        switch self {
        case .smoothest:          return 0.10
        case .chillFewCrossings:  return 0.05
        case .fastMildRoughness:  return -0.05
        case .trickSpotCrawl:     return -0.10
        case .nightSafe:          return 0.08
        }
    }

    // MARK: - UX Strings

    /// Short label for chips/segmented controls (localized).
    public var label: String {
        switch self {
        case .smoothest:          return NSLocalizedString("Smoothest", comment: "ride mode")
        case .chillFewCrossings:  return NSLocalizedString("Chill", comment: "ride mode")
        case .fastMildRoughness:  return NSLocalizedString("Fast", comment: "ride mode")
        case .trickSpotCrawl:     return NSLocalizedString("Trick Crawl", comment: "ride mode")
        case .nightSafe:          return NSLocalizedString("Night Safe", comment: "ride mode")
        }
    }

    /// Descriptive subtitle for tooltips/footers (localized).
    public var detail: String {
        switch self {
        case .smoothest:
            return NSLocalizedString("Prioritize buttery pavement and low grade.", comment: "ride mode detail")
        case .chillFewCrossings:
            return NSLocalizedString("Keep it mellow with fewer crossings.", comment: "ride mode detail")
        case .fastMildRoughness:
            return NSLocalizedString("Faster line; tolerates mild roughness.", comment: "ride mode detail")
        case .trickSpotCrawl:
            return NSLocalizedString("Short hops between nearby spots.", comment: "ride mode detail")
        case .nightSafe:
            return NSLocalizedString("Favor lit paths and safer corridors.", comment: "ride mode detail")
        }
    }

    /// SF Symbol name to render alongside the label.
    public var icon: String {
        switch self {
        case .smoothest:          return "figure.skating"
        case .chillFewCrossings:  return "leaf"
        case .fastMildRoughness:  return "tortoise.fill" // ironic; swap to a fast glyph if preferred
        case .trickSpotCrawl:     return "sparkles"
        case .nightSafe:          return "moon.stars.fill"
        }
    }

    // MARK: - Routing Tuning

    /// Per-mode routing preferences consumed by the reducer/engine.
    public var tuning: RouteTuning {
        switch self {
        case .smoothest:
            return .init(
                smoothnessWeight: 1.00,
                maxGradePercent: 5.0,
                avoidStairs: true,
                avoidHighSpeedTraffic: true,
                crossingsPenaltyWeight: 0.55,
                nightLightingPreference: 0.0,
                speedCapKmh: 22,
                pathPreference: 0.85,
                trickSpotAttraction: 0.0
            )

        case .chillFewCrossings:
            return .init(
                smoothnessWeight: 0.85,
                maxGradePercent: 6.0,
                avoidStairs: true,
                avoidHighSpeedTraffic: true,
                crossingsPenaltyWeight: 0.80,
                nightLightingPreference: 0.0,
                speedCapKmh: 20,
                pathPreference: 0.80,
                trickSpotAttraction: 0.0
            )

        case .fastMildRoughness:
            return .init(
                smoothnessWeight: 0.55,
                maxGradePercent: 8.0,
                avoidStairs: true,
                avoidHighSpeedTraffic: false,
                crossingsPenaltyWeight: 0.20,
                nightLightingPreference: 0.0,
                speedCapKmh: 28,
                pathPreference: 0.55,
                trickSpotAttraction: 0.0
            )

        case .trickSpotCrawl:
            return .init(
                smoothnessWeight: 0.40,
                maxGradePercent: 7.0,
                avoidStairs: false, // stairs OK to be near; engine should not traverse them
                avoidHighSpeedTraffic: true,
                crossingsPenaltyWeight: 0.35,
                nightLightingPreference: 0.0,
                speedCapKmh: 16,
                pathPreference: 0.65,
                trickSpotAttraction: 1.0
            )

        case .nightSafe:
            return .init(
                smoothnessWeight: 0.90,
                maxGradePercent: 5.0,
                avoidStairs: true,
                avoidHighSpeedTraffic: true,
                crossingsPenaltyWeight: 0.65,
                nightLightingPreference: 1.0,
                speedCapKmh: 20,
                pathPreference: 0.90,
                trickSpotAttraction: 0.0
            )
        }
    }

    // MARK: - Power / Telemetry Hints

    /// Hint to `LocationManagerService` for power targets when navigating in this mode.
    /// Expressed as approx. max battery burn per hour (% of battery capacity).
    public var batteryBudgetPercentPerHour: Double {
        switch self {
        case .smoothest:          return 7.0
        case .chillFewCrossings:  return 6.5
        case .fastMildRoughness:  return 8.0
        case .trickSpotCrawl:     return 6.0
        case .nightSafe:          return 7.0
        }
    }

    /// Suggested min horizontal accuracy for GPS (meters) while actively navigating this mode.
    public var suggestedAccuracyMeters: Double {
        switch self {
        case .smoothest:          return 12
        case .chillFewCrossings:  return 15
        case .fastMildRoughness:  return 10
        case .trickSpotCrawl:     return 15
        case .nightSafe:          return 12
        }
    }
}

// MARK: - Persistence

public enum RideModeStore {
    private static let key = "RideModeStore.selected"
    public static let `default`: RideMode = .smoothest

    public static func load() -> RideMode {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let mode = RideMode(rawValue: raw) else { return `default` }
        return mode
    }

    public static func save(_ mode: RideMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: key)
    }
}

// MARK: - Bridging helpers (optional compile-time sugar)

public extension RideMode {
    /// Short accessibility phrase pairing icon concept + label.
    var accessibilityLabel: String {
        switch self {
        case .smoothest:          return NSLocalizedString("Smoothest route", comment: "a11y")
        case .chillFewCrossings:  return NSLocalizedString("Chill route with fewer crossings", comment: "a11y")
        case .fastMildRoughness:  return NSLocalizedString("Fast route allowing mild roughness", comment: "a11y")
        case .trickSpotCrawl:     return NSLocalizedString("Trick crawl between spots", comment: "a11y")
        case .nightSafe:          return NSLocalizedString("Night safe route", comment: "a11y")
        }
    }

    /// Lightweight map to a coarser app-wide routing intent where needed.
    /// Use when a subsystem only understands broad buckets.
    var coarseRoutingIntent: CoarseRoutingIntent {
        switch self {
        case .smoothest, .chillFewCrossings, .nightSafe: return .smoothest
        case .fastMildRoughness:                         return .fastest
        case .trickSpotCrawl:                            return .explore
        }
    }
}

/// Coarse buckets used by legacy or external modules.
/// Keep this separate so RideMode can evolve without breaking call sites.
public enum CoarseRoutingIntent: String, Codable, Sendable {
    case smoothest
    case fastest
    case explore
}


