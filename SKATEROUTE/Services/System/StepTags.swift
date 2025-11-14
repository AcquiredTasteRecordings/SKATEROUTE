// Services/System/StepTags.swift
// Canonical attribute bag shared across attribution, routing context, and scoring.

import Foundation

/// Lightweight metadata describing per-step attributes surfaced by attribution providers.
/// Matches the contract documented in `AttributionService` and consumed by
/// `RouteContextBuilder` / `SkateRouteScorer`.
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

