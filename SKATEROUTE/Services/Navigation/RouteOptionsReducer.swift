// Services/RouteOptionsReducer.swift
// Turns raw RouteCandidates into ranked, display-ready options.

import Foundation
import MapKit
import UIKit

public final class RouteOptionsReducer: RouteOptionsReducing {

    // MARK: - Presentation Model
    public struct Presentation {
        public struct StepPaint {
            public let stepIndex: Int
            public let color: UIColor
        }

        public let id: String
        public let title: String          // e.g., "Fastest" or "Option A"
        public let subtitle: String       // e.g., "12.3 km • 41 min • Grade: Friendly"
        public let distanceText: String   // localized distance
        public let etaText: String        // localized ETA (duration)
        public let score: Double          // 0–100 (scaler defined by scorer)
        public let scoreLabel: String     // short descriptor from scorer
        public let tintColor: UIColor     // color keyed to score for cards/buttons
        public let stepPaints: [StepPaint]// precomputed polyline step colors

        public init(
            id: String,
            title: String,
            subtitle: String,
            distanceText: String,
            etaText: String,
            score: Double,
            scoreLabel: String,
            tintColor: UIColor,
            stepPaints: [StepPaint]
        ) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.distanceText = distanceText
            self.etaText = etaText
            self.score = score
            self.scoreLabel = scoreLabel
            self.tintColor = tintColor
            self.stepPaints = stepPaints
        }
    }

    // MARK: - Dependencies

    private let scorer: SkateRouteScoring

    public init(scorer: SkateRouteScoring) {
        self.scorer = scorer
    }

    // MARK: - Contract

    public func evaluate(
        candidates: [RouteService.RouteCandidate],
        mode: RideMode
    ) -> [String: Presentation] {
        guard !candidates.isEmpty else { return [:] }

        // Compute a route-level score for each candidate.
        // We don’t yet have measured roughness at plan time, so pass 0 as neutral baseline.
        // Slope penalty is a mode-dependent knob; tune as needed later.
        let slopePenalty = Self.defaultSlopePenalty(for: mode)
        let enriched: [(RouteService.RouteCandidate, Double, UIColor, String)] = candidates.map { cand in
            let score = scorer.computeScore(
                for: cand.route,
                roughnessRMS: 0.0,
                slopePenalty: slopePenalty,
                mode: mode
            )
            let label = scorer.gradeDescription(for: score)
            let color = scorer.color(for: score)
            return (cand, score, color, label)
        }

        // Choose labels: fastest gets “Fastest”, highest score gets “Best Surface”.
        // If they’re the same, keep “Best Route”.
        let fastestId = enriched
            .min(by: { $0.0.route.expectedTravelTime < $1.0.route.expectedTravelTime })?.0.id
        let bestScoreId = enriched
            .max(by: { $0.1 < $1.1 })?.0.id

        var out: [String: Presentation] = [:]
        for (idx, item) in enriched.enumerated() {
            let cand = item.0
            let route = cand.route
            let score = item.1
            let scoreLabel = item.3
            let tint = item.2

            let distanceText = Self.formatDistance(route.distance)
            let etaText = Self.formatETA(route.expectedTravelTime)

            let title: String = {
                switch cand.id {
                case fastestId where bestScoreId == fastestId:
                    return "Best Route"
                case fastestId:
                    return "Fastest"
                case bestScoreId:
                    return "Best Surface"
                default:
                    // A/B/C labels for consistency across sessions
                    return "Option \(String(UnicodeScalar(65 + idx)!))"
                }
            }()

            // Friendly subtitle with key facts
            let subtitle = "\(distanceText) • \(etaText) • \(scoreLabel)"

            // Precompute per-step paints so the UI can render colored polylines cheaply.
            let paints: [Presentation.StepPaint] = cand.stepContexts.enumerated().map { pair in
                Presentation.StepPaint(stepIndex: pair.offset, color: tint)
            }

            out[cand.id] = Presentation(
                id: cand.id,
                title: title,
                subtitle: subtitle,
                distanceText: distanceText,
                etaText: etaText,
                score: score,
                scoreLabel: scoreLabel,
                tintColor: tint,
                stepPaints: paints
            )
        }

        return out
    }

    // MARK: - Helpers

    private static func defaultSlopePenalty(for mode: RideMode) -> Double {
        // Soft default; tweak with product telemetry later.
        // Higher number means steeper hills get penalized more.
        switch mode {
        // Extend with cases if RideMode becomes an enum; default keeps us compile-safe today.
        default: return 1.0
        }
    }

    private static func formatDistance(_ meters: CLLocationDistance) -> String {
        // Simple, locale-aware format (metric/imperial handled by MeasurementFormatter)
        let measurement = Measurement(value: meters / 1000.0, unit: UnitLength.kilometers)
        let fmt = MeasurementFormatter()
        fmt.unitOptions = .naturalScale
        fmt.unitStyle = .medium
        fmt.numberFormatter.maximumFractionDigits = meters < 5000 ? 1 : 0
        return fmt.string(from: measurement)
    }

    private static func formatETA(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hrs = minutes / 60
        let mins = minutes % 60
        if mins == 0 { return "\(hrs) hr" }
        return "\(hrs) hr \(mins) min"
    }
}


