//  Support/Models/StepTags.swift
//  Shared attribution tags used by route services and scoring.
//
//  Provides a lightweight description of bike lane coverage,
//  surface quality, and known hazards for a route step.

import Foundation

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
