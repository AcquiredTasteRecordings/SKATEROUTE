// Services/System/StepTags.swift
// Canonical representation of per-step attribution hints.
// Shared across navigation, overlays, and scoring.

import Foundation

/// Metadata describing infrastructure, hazards, and surface hints for a route step.
/// Values default to neutral so callers can opt-in to specifics without worrying about
/// partial data availability.
public struct StepTags: Sendable, Equatable {
    public var hasProtectedLane: Bool
    public var hasPaintedLane: Bool
    public var surfaceRough: Bool
    public var hazardCount: Int
    public var highwayClass: String?
    public var surface: String?

    public init(hasProtectedLane: Bool = false,
                hasPaintedLane: Bool = false,
                surfaceRough: Bool = false,
                hazardCount: Int = 0,
                highwayClass: String? = nil,
                surface: String? = nil) {
        self.hasProtectedLane = hasProtectedLane
        self.hasPaintedLane = hasPaintedLane
        self.surfaceRough = surfaceRough
        self.hazardCount = max(0, hazardCount)
        self.highwayClass = highwayClass
        self.surface = surface
    }
}

public extension StepTags {
    /// Baseline, no-data set of tags. Prefer this over `StepTags()` to keep behaviour consistent
    /// across call sites and simplify future migrations (e.g. adding defaults).
    static let neutral = StepTags()
}
