// Services/SkateRouteScorer.swift
// Unified route/step scorer used by planner, overlays, and HUD.
// Consistent with RideMode.RouteTuning + Attribution (StepTags), battery-light, deterministic.
// Produces normalized scores (0…1), letter grades, human labels, and colors for rendering.

import Foundation
import MapKit
import UIKit
import OSLog

public final class SkateRouteScorer {

    // MARK: - Types

    /// Optional rider skill bias. Keeps the UX simple but allows personalization.
    public enum SkillLevel: Sendable {
        case beginner, intermediate, advanced

        var multiplier: Double {
            switch self {
            case .beginner:     return 0.90
            case .intermediate: return 1.00
            case .advanced:     return 1.08
            }
        }
    }

    /// Minimal context derived from attribution + geometry per step.
    /// Prefer constructing from `StepTags` via `StepContext.init(tags:turnRadians:)`.
    public struct StepContext: Sendable, Equatable {
        public var hasProtectedLane: Bool
        public var hasPaintedLane: Bool
        public var surfaceRough: Bool
        public var hazardCount: Int
        /// Absolute turn angle in radians for the upcoming maneuver (0 = straight).
        public var turnRadians: Double

        public init(hasProtectedLane: Bool = false,
                    hasPaintedLane: Bool = false,
                    surfaceRough: Bool = false,
                    hazardCount: Int = 0,
                    turnRadians: Double = 0) {
            self.hasProtectedLane = hasProtectedLane
            self.hasPaintedLane   = hasPaintedLane
            self.surfaceRough     = surfaceRough
            self.hazardCount      = max(0, hazardCount)
            self.turnRadians      = max(0, turnRadians)
        }

        /// Lane bonus in [0, 1]
        public var laneBonus: Double {
            if hasProtectedLane { return 1.0 }
            if hasPaintedLane { return 0.5 }
            return 0.0
        }

        /// Turn penalty in [0, 1] (0 = straight, 1 = hairpin).
        public var turnPenalty: Double {
            min(1.0, turnRadians / .pi)
        }

        /// Hazard penalty in [0, 1] with diminishing effect.
        public var hazardPenalty: Double {
            1.0 - 1.0 / (1.0 + Double(hazardCount)) // 0, 0.5, 0.67, 0.75, …
        }
    }

    /// Detailed breakdown used for diagnostics/UI.
    public struct Breakdown: Sendable {
        public let roughnessFactor: Double
        public let slopeFactor: Double
        public let lanesFactor: Double
        public let turnFactor: Double
        public let hazardFactor: Double
        public let modeBiasApplied: Double
        public let skillApplied: Double
        public let finalScore: Double
    }

    public struct Grade: Sendable, Equatable {
        public let score: Double     // 0…1
        public let letter: String    // A/B/C
        public let label: String     // Butter / Chill / Sketchy
        public let color: UIColor
    }

    // MARK: - Config

    private let logger = Logger(subsystem: "com.yourcompany.skateroute", category: "Scorer")

    private let skill: SkillLevel

    /// Hard bounds to map physical inputs into 0…1 factors.
    private struct Bounds {
        let roughnessRMSMax: Double = 3.5     // ~3.5 RMS = very rough asphalt
        let slopePenaltyMax: Double = 1.0     // 1.0 means fully unacceptable slope
        let maxUsefulSpeedKmh: Double = 32
    }
    private let bounds = Bounds()

    public init(skillLevel: SkillLevel = .intermediate) {
        self.skill = skillLevel
    }

    // MARK: - Public scoring API

    /// Route-level composite score. Cheap to compute and stable across devices.
    /// - Parameters:
    ///   - roughnessRMS: aggregated route roughness (RMS), from MotionRoughnessService fusion or attribution.
    ///   - slopePenalty: 0…1 normalized penalty from ElevationService (grade > cap → increase).
    ///   - mode: chosen RideMode (applies tuning + bias).
    /// - Returns: (score 0…1, breakdown)
    public func routeScore(roughnessRMS: Double,
                           slopePenalty: Double,
                           mode: RideMode) -> (Double, Breakdown) {

        let t: RouteTuning = mode.tuning

        // Normalized, clamped components
        let roughFactor = clamp01(1.0 - (roughnessRMS / bounds.roughnessRMSMax))
        let slopeFactor = clamp01(1.0 - clamp01(slopePenalty))

        // Weighted blend from RouteTuning
        var score = mix(roughFactor, slopeFactor, w1: t.smoothnessWeight, w2: 1.0 - t.smoothnessWeight)

        // Enforce grade preference cap (soft wall)
        if let cap = t.maxGradePercent {
            // If slopePenalty implies >cap, dampen score a bit more.
            score *= capSoftWall(slopePenalty, capPercent: cap)
        }

        // Mode bias (subtle)
        score = clamp01(score + mode.bias)

        // Skill bias
        score *= skill.multiplier

        let breakdown = Breakdown(
            roughnessFactor: roughFactor,
            slopeFactor: slopeFactor,
            lanesFactor: 1.0,
            turnFactor: 1.0,
            hazardFactor: 1.0,
            modeBiasApplied: mode.bias,
            skillApplied: skill.multiplier,
            finalScore: clamp01(score)
        )

        #if DEBUG
        logger.debug("RouteScore r=\(roughnessRMS, privacy: .public) sPen=\(slopePenalty, privacy: .public) → \(score, privacy: .public)")
        #endif

        return (clamp01(score), breakdown)
    }

    /// Step-level score with contextual tags (lanes/turn/hazards).
    /// Supply the same `roughnessRMS`/`slopePenalty` scaling as route-level for consistency.
    public func stepScore(roughnessRMS: Double,
                          slopePenalty: Double,
                          mode: RideMode,
                          context: StepContext) -> (Double, Breakdown) {

        var (base, rb) = routeScore(roughnessRMS: roughnessRMS, slopePenalty: slopePenalty, mode: mode)

        // Lanes act as a bonus (multiplicative to preserve normalization feel).
        // Turn/hazards are penalties. Keep them mild so the main drivers remain roughness/slope.
        let laneBoost = 1.0 + 0.10 * context.laneBonus        // up to +10%
        let turnFactor = clamp01(1.0 - 0.35 * context.turnPenalty)
        let hazardFactor = clamp01(1.0 - 0.40 * context.hazardPenalty)

        base = clamp01(base * laneBoost * turnFactor * hazardFactor)

        let breakdown = Breakdown(
            roughnessFactor: rb.roughnessFactor,
            slopeFactor: rb.slopeFactor,
            lanesFactor: laneBoost,
            turnFactor: turnFactor,
            hazardFactor: hazardFactor,
            modeBiasApplied: rb.modeBiasApplied,
            skillApplied: rb.skillApplied,
            finalScore: base
        )

        #if DEBUG
        logger.debug("StepScore → \(base, privacy: .public) (lane \(laneBoost, privacy: .public), turn \(turnFactor, privacy: .public), haz \(hazardFactor, privacy: .public))")
        #endif

        return (base, breakdown)
    }

    // MARK: - Grading / Colors

    public enum Palette {
        case standard       // red → yellow → green
        case heatmap        // blue → green → red
        case highContrast   // WCAG-friendly: red → amber → green with stronger separation
    }

    /// Convert a normalized score to a user-facing grade bundle.
    public func grade(for score: Double, palette: Palette = .standard) -> Grade {
        let s = clamp01(score)
        let letter: String
        let label: String

        switch s {
        case 0.85...1.0:
            letter = "A"; label = NSLocalizedString("Butter Smooth", comment: "grade")
        case 0.60..<0.85:
            letter = "B"; label = NSLocalizedString("Chill", comment: "grade")
        default:
            letter = "C"; label = NSLocalizedString("Sketchy", comment: "grade")
        }

        return Grade(score: s, letter: letter, label: label, color: color(for: s, palette: palette))
    }

    /// Color map tuned for readability on dark maps (works fine on light as well).
    public func color(for score: Double, palette: Palette = .standard) -> UIColor {
        let s = clamp01(score)

        switch palette {
        case .standard:
            // Red (0) → Yellow (0.5) → Green (1)
            // Use a simple two-piece lerp with gamma for smoother mid-tones.
            if s < 0.5 {
                let t = pow(s / 0.5, 0.9)
                let r = 1.0
                let g = 0.25 + 0.75 * t
                return UIColor(red: r, green: g, blue: 0.20, alpha: 1.0)
            } else {
                let t = pow((s - 0.5) / 0.5, 0.9)
                let r = 1.0 - 0.8 * t
                let g = 1.0
                return UIColor(red: r, green: g, blue: 0.20, alpha: 1.0)
            }

        case .heatmap:
            // Blue → Green → Red for analytics heat layers.
            if s < 0.5 {
                let t = s / 0.5
                return UIColor(red: 0.0, green: CGFloat(t), blue: 1.0 - CGFloat(t), alpha: 1.0)
            } else {
                let t = (s - 0.5) / 0.5
                return UIColor(red: CGFloat(t), green: 1.0 - CGFloat(t), blue: 0.0, alpha: 1.0)
            }

        case .highContrast:
            // Hard stops with stronger luminance separation (a11y).
            if s >= 0.85 { return UIColor(red: 0.00, green: 0.85, blue: 0.30, alpha: 1.0) }   // green
            if s >= 0.60 { return UIColor(red: 0.95, green: 0.70, blue: 0.10, alpha: 1.0) }   // amber
            return UIColor(red: 0.88, green: 0.20, blue: 0.18, alpha: 1.0)                    // red
        }
    }

    // MARK: - Helpers

    /// Soft wall that reduces scores when expected grade exceeds a preferred cap.
    private func capSoftWall(_ slopePenalty: Double, capPercent: Double) -> Double {
        // Slope penalty already normalized 0…1 by ElevationService.
        // We just bend the top 40% down a bit more to respect low grade preferences.
        // Example: at penalty 0.6 → multiplier ≈ 0.9; at 0.9 → ≈ 0.75.
        let p = clamp01(slopePenalty)
        let t = smoothstep(0.60, 1.00, p)
        return 1.0 - 0.25 * t
    }

    private func clamp01(_ v: Double) -> Double { max(0, min(1, v)) }

    /// Weighted blend of two factors; weights don’t have to sum to 1 (we normalize).
    private func mix(_ a: Double, _ b: Double, w1: Double, w2: Double) -> Double {
        let w = max(0.0001, w1 + w2)
        return (a * w1 + b * w2) / w
    }

    /// Smoothstep with custom edge (Hermite interpolation).
    private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = clamp01((x - edge0) / max(1e-6, (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
}

// MARK: - StepContext adapter from StepTags (if available)

#if canImport(MapKit)
/// If your project defines `StepTags` (as used by AttributionService), bridge it here.
/// Expected shape: hasProtectedLane, hasPaintedLane, surfaceRough, hazardCount.
public extension SkateRouteScorer.StepContext {
    init(tags: StepTags, turnRadians: Double) {
        self.init(
            hasProtectedLane: tags.hasProtectedLane,
            hasPaintedLane: tags.hasPaintedLane,
            surfaceRough: tags.surfaceRough,
            hazardCount: tags.hazardCount,
            turnRadians: turnRadians
        )
    }
}
#endif

// MARK: - Convenience for overlays

public extension SkateRouteScorer {
    /// Map per-step scores into UIColors for overlay rendering (one color per step).
    func colors(for stepScores: [Double], palette: Palette = .standard) -> [UIColor] {
        stepScores.map { color(for: $0, palette: palette) }
    }

    /// Produce a label suitable for badges/tooltips.
    func label(for score: Double) -> String { grade(for: score).label }
}

// MARK: - AppDI protocol bridge
extension SkateRouteScorer: SkateRouteScoring {
    public func computeScore(for route: MKRoute,
                             roughnessRMS: Double,
                             slopePenalty: Double,
                             mode: RideMode) -> Double {
        // Route geometry is currently unused for the aggregate score. We may incorporate
        // lane metadata or hazard density later once AttributionService feeds it here.
        let (score, _) = routeScore(roughnessRMS: roughnessRMS,
                                    slopePenalty: slopePenalty,
                                    mode: mode)
        return score
    }

    public func gradeDescription(for score: Double) -> String {
        grade(for: score).label
    }

    public func color(for score: Double) -> UIColor {
        color(for: score)
    }
}


