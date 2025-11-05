// Services/RouteOptionsReducer.swift
import Foundation
import MapKit

/// Scores route candidates and produces lightweight presentation metadata used by the planner UI.
public final class RouteOptionsReducer {
    public struct Presentation {
        public let title: String
        public let detail: String
        public let score: Double
        public let scoreLabel: String
        public let roughnessEstimate: Double
    }

    private let scorer: SkateRouteScorer

    public init(scorer: SkateRouteScorer = AppDI.shared.routeScorer) {
        self.scorer = scorer
    }

    public func evaluate(candidates: [RouteService.RouteCandidate], mode: RideMode) -> [String: Presentation] {
        guard !candidates.isEmpty else { return [:] }

        let fastest = candidates.min { $0.route.expectedTravelTime < $1.route.expectedTravelTime }
        let smoothest = candidates.min { lhs, rhs in
            lhs.metadata.surface.roughFraction < rhs.metadata.surface.roughFraction
        }
        let mostProtected = candidates.max { lhs, rhs in
            lhs.metadata.surface.protectedFraction < rhs.metadata.surface.protectedFraction
        }

        var results: [String: Presentation] = [:]

        let sortedByScore = candidates.sorted { lhs, rhs in
            computeScore(for: lhs, mode: mode) > computeScore(for: rhs, mode: mode)
        }
        let recommendedId = sortedByScore.first?.id

        for candidate in candidates {
            let score = computeScore(for: candidate, mode: mode)
            let roughness = roughnessEstimate(for: candidate)
            let label = title(for: candidate,
                              recommended: recommendedId,
                              fastest: fastest?.id,
                              smoothest: smoothest?.id,
                              mostProtected: mostProtected?.id)
            let detail = detailText(for: candidate)
            let scoreLabel = scorer.gradeDescription(for: score)
            results[candidate.id] = Presentation(title: label,
                                                 detail: detail,
                                                 score: score,
                                                 scoreLabel: scoreLabel,
                                                 roughnessEstimate: roughness)
        }

        return results
    }
}

private extension RouteOptionsReducer {
    func computeScore(for candidate: RouteService.RouteCandidate, mode: RideMode) -> Double {
        let roughness = roughnessEstimate(for: candidate)
        return scorer.computeScore(for: candidate.route,
                                   roughnessRMS: roughness,
                                   slopePenalty: candidate.metadata.grade.slopePenalty,
                                   mode: mode)
    }

    func roughnessEstimate(for candidate: RouteService.RouteCandidate) -> Double {
        // 0.08 RMS (butter) + fraction of rough surface scaled into a plausible range.
        0.08 + candidate.metadata.surface.roughFraction * 0.35
    }

    func title(for candidate: RouteService.RouteCandidate,
               recommended: String?,
               fastest: String?,
               smoothest: String?,
               mostProtected: String?) -> String {
        if candidate.id == recommended { return "Recommended" }
        if candidate.id == fastest { return "Fastest" }
        if candidate.id == smoothest { return "Smoothest" }
        if candidate.id == mostProtected { return "Protected" }
        return "Alternate"
    }

    func detailText(for candidate: RouteService.RouteCandidate) -> String {
        let minutes = Int(round(candidate.route.expectedTravelTime / 60))
        let distanceKm = candidate.route.distance / 1000.0
        let distanceString = String(format: "%.1f km", distanceKm)
        let slope = String(format: "%.0f%%", candidate.metadata.grade.maxGrade)
        let surface = candidate.metadata.surface.dominantSurface ?? "Mixed"

        var components: [String] = []
        components.append("\(minutes) min")
        components.append(distanceString)
        components.append("Slope \(slope)")
        components.append(surface)

        return components.joined(separator: " · ")
    }
}
