// Services/Navigation/StepTags.swift
// Canonical step-level metadata shared across navigation services.

import Foundation

/// Lightweight, value-semantic representation of attributed step metadata.
/// Used by attribution providers, context builders, and scoring bridges.
public struct StepTags: Sendable, Equatable {
    public var hasProtectedLane: Bool
    public var hasPaintedLane: Bool
    public var surfaceRough: Bool
    public var hazardCount: Int
    public var highwayClass: String?
    public var surface: String?
    /// Optional auxiliary metadata (string-encoded for portability).
    public var metadata: [String: String]

    public init(hasProtectedLane: Bool = false,
                hasPaintedLane: Bool = false,
                surfaceRough: Bool = false,
                hazardCount: Int = 0,
                highwayClass: String? = nil,
                surface: String? = nil,
                metadata: [String: String] = [:]) {
        self.hasProtectedLane = hasProtectedLane
        self.hasPaintedLane = hasPaintedLane
        self.surfaceRough = surfaceRough
        self.hazardCount = max(0, hazardCount)
        self.highwayClass = highwayClass
        self.surface = surface
        self.metadata = metadata
    }
}

public extension StepTags {
    /// Neutral tags to represent unknown attribution (cache miss, no coverage).
    static var neutral: StepTags { StepTags() }

    /// True when no metadata or positive signals have been recorded.
    var isNeutral: Bool {
        !hasProtectedLane &&
        !hasPaintedLane &&
        !surfaceRough &&
        hazardCount == 0 &&
        highwayClass == nil &&
        surface == nil &&
        metadata.isEmpty
    }
}
