// Services/SkateRouteScorer.swift
import Foundation
import MapKit
import UIKit   // needed for UIColor

/// SkateRouteScorer is responsible for scoring skate routes based on their smoothness, slope, and additional contextual factors such as lane presence, turns, and hazards.
/// It adapts scoring based on the rider's skill level to provide a personalized assessment of route quality.
public final class SkateRouteScorer {

    // MARK: - Weight tuning constants
    private let roughnessWeight = 0.7
    private let slopeWeight = 0.3
    private let laneBonusMultiplier = 1.0
    private let hazardPenaltyWeight = 1.0
    private let turnPenaltyWeight = 1.0

    public enum SkillLevel {
        case beginner
        case intermediate
        case advanced
    }

    private var skillBias: Double {
        switch skillLevel {
        case .beginner:
            return 0.85
        case .intermediate:
            return 1.0
        case .advanced:
            return 1.1
        }
    }

    private let skillLevel: SkillLevel

    public init(skillLevel: SkillLevel = .intermediate) {
        self.skillLevel = skillLevel
    }

    // Base scorer (roughness + slope + mode bias). Returns 0...1
    public func computeScore(for route: MKRoute,
                             roughnessRMS: Double,
                             slopePenalty: Double,
                             mode: RideMode) -> Double {
        // 0 (worst) → 1 (best)
        let roughFactor = max(0, 1.0 - min(roughnessRMS / 3.5, 1.0))
        let slopeFactor = max(0, 1.0 - slopePenalty)
        var score = roughnessWeight * roughFactor + slopeWeight * slopeFactor

        switch mode {
        case .chillFewCrossings:
            score *= 0.95
        case .nightSafe:
            score *= 0.90
        case .fastMildRoughness:
            score *= 1.05
        default:
            break
        }

        score *= skillBias

        return max(0, min(score, 1))
    }

    // Per-step scorer with context (lanes / turns / hazards). Returns 0...1
    public func computeScore(for route: MKRoute,
                             roughnessRMS: Double,
                             slopePenalty: Double,
                             mode: RideMode,
                             stepContext: StepContext) -> Double {
        var base = computeScore(for: route,
                                roughnessRMS: roughnessRMS,
                                slopePenalty: slopePenalty,
                                mode: mode)
        // Boost for lanes
        base *= (1.0 + laneBonusMultiplier * stepContext.laneBonus)
        // Penalties
        base *= max(0.0, 1.0 - turnPenaltyWeight * stepContext.turnPenalty)
        base *= max(0.0, 1.0 - hazardPenaltyWeight * stepContext.hazardPenalty)

        #if DEBUG
        print("Step score: \(base)")
        #endif

        return max(0, min(base, 1))
    }

    // Color mapping helper with optional gradient modes (standard and heatmap)
    public func color(forScore score: Double, mode: String = "standard") -> UIColor {
        let clamped = max(0, min(score, 1))
        switch mode.lowercased() {
        case "heatmap":
            // Heatmap: blue (low) → green (mid) → red (high)
            if clamped < 0.5 {
                let ratio = CGFloat(clamped * 2)
                return UIColor(red: 0.0, green: ratio, blue: 1.0 - ratio, alpha: 1.0)
            } else {
                let ratio = CGFloat((clamped - 0.5) * 2)
                return UIColor(red: ratio, green: 1.0 - ratio, blue: 0.0, alpha: 1.0)
            }
        default:
            // Standard: red → yellow → green
            let r = CGFloat(1.0 - clamped)
            let g = CGFloat(0.5 + 0.5 * clamped)
            let b = CGFloat(0.2)
            return UIColor(red: r, green: g, blue: b, alpha: 1.0)
        }
    }

    /// Returns a human-readable description for a given score.
    public func gradeDescription(for score: Double) -> String {
        let clamped = max(0, min(score, 1))
        switch clamped {
        case 0.85...1.0:
            return "Butter Smooth"
        case 0.6..<0.85:
            return "Chill"
        default:
            return "Sketchy"
        }
    }
}
