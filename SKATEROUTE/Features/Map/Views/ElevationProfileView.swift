// Features/Map/Views/ElevationProfileView.swift
// Compact, accessible elevation/grade profile with optional scrub interaction.
// Renders percent grade per step; fills above/below baseline and exposes a progress marker.
// Battery-light (pure SwiftUI Path), Dynamic Type–safe, and VoiceOver-friendly.

import SwiftUI
import UIKit

public struct ElevationProfileView: View {
    // MARK: Inputs
    private let summary: GradeSummary?
    private let showsStats: Bool
    private let onScrubChanged: ((Double) -> Void)?
    @Binding private var progress: Double // 0…1 along the route; used for the scrub marker

    // MARK: Environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: Init
    /// - Parameters:
    ///   - summary: A `GradeSummary` describing step grades (percent units, e.g. 6.0 = 6%).
    ///   - progress: Optional binding 0…1 for a live scrub marker (omit for non-interactive).
    ///   - showsStats: Show headline “Elevation” + max grade badge.
    ///   - onScrubChanged: Callback as the user scrubs (0…1). Fires on end with final value.
    public init(
        summary: GradeSummary?,
        progress: Binding<Double> = .constant(-1),          // pass .constant(-1) to hide marker
        showsStats: Bool = true,
        onScrubChanged: ((Double) -> Void)? = nil
    ) {
        self.summary = summary
        self._progress = progress
        self.showsStats = showsStats
        self.onScrubChanged = onScrubChanged
    }

    // MARK: Body
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsStats {
                header
            }

            GeometryReader { proxy in
                ZStack {
                    // Baseline
                    baseline(in: proxy.size)
                        .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    // Filled areas (above = climb, below = descent)
                    if let summary, summary.stepGrades.count > 1 {
                        let paths = filledPaths(for: summary.stepGrades, size: proxy.size)
                        paths.climb
                            .fill(LinearGradient(
                                colors: [Color.green.opacity(0.28), Color.green.opacity(0.10)],
                                startPoint: .top, endPoint: .bottom))
                        paths.descent
                            .fill(LinearGradient(
                                colors: [Color.red.opacity(0.30), Color.red.opacity(0.12)],
                                startPoint: .bottom, endPoint: .top))
                    }

                    // Profile line
                    profilePath(in: proxy.size)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineJoin: .round))

                    // Flat fallback
                    if (summary?.stepGrades ?? []).allSatisfy({ abs($0) < 0.1 }) {
                        Text("Flat route")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Scrub marker if progress is in [0,1]
                    if progress >= 0, progress <= 1 {
                        scrubMarker(in: proxy.size, progress: progress)
                    }
                }
                .contentShape(Rectangle()) // for drag anywhere
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard summary?.stepGrades.isEmpty == false else { return }
                        let p = clamp(value.location.x / max(proxy.size.width, 1), 0, 1)
                        if progress < 0 { progress = 0 } // reveal on first drag
                        progress = p
                        onScrubChanged?(p)
                    }
                    .onEnded { value in
                        guard summary?.stepGrades.isEmpty == false else { return }
                        let p = clamp(value.location.x / max(proxy.size.width, 1), 0, 1)
                        progress = p
                        onScrubChanged?(p)
                    }
                )
            }
            .frame(height: 96)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemBackground)))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary())
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Elevation")
                .font(.headline)
            Spacer()
            if let summary {
                let maxUp = summary.stepGrades.max() ?? 0
                let maxDown = summary.stepGrades.min() ?? 0
                HStack(spacing: 8) {
                    if maxUp > 0.1 {
                        labelBadge(title: "Max ↑", value: maxUp)
                    }
                    if maxDown < -0.1 {
                        labelBadge(title: "Max ↓", value: abs(maxDown))
                    }
                }
                .transition(.opacity)
            }
        }
    }

    private func labelBadge(title: String, value: Double) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption2.weight(.semibold))
            Text(String(format: "%.0f%%", value)).font(.caption2.monospacedDigit())
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 1))
        .accessibilityLabel("\(title) \(Int(value)) percent")
    }

    // MARK: Paths

    private func baseline(in size: CGSize) -> Path {
        var path = Path()
        let midY = size.height / 2
        path.move(to: CGPoint(x: 0, y: midY))
        path.addLine(to: CGPoint(x: size.width, y: midY))
        return path
    }

    private func profilePath(in size: CGSize) -> Path {
        var path = Path()
        guard let summary, summary.stepGrades.count > 1 else { return path }
        let values = summary.stepGrades
        let maxAbs = max(values.map { abs($0) }.max() ?? 1, 1)
        let midY = size.height / 2
        let height = size.height / 2 - 8
        let stepWidth = size.width / CGFloat(values.count - 1)

        path.move(to: CGPoint(x: 0, y: midY))
        for (index, grade) in values.enumerated() {
            let x = CGFloat(index) * stepWidth
            let normalized = CGFloat(grade / maxAbs)
            let y = midY - normalized * height
            path.addLine(to: CGPoint(x: x, y: y))
        }
        return path
    }

    /// Build separate fill paths above and below baseline for pleasant visuals.
    private func filledPaths(for values: [Double], size: CGSize) -> (climb: Path, descent: Path) {
        let maxAbs = max(values.map { abs($0) }.max() ?? 1, 1)
        let midY = size.height / 2
        let height = size.height / 2 - 8
        let stepWidth = size.width / CGFloat(max(values.count - 1, 1))

        var climb = Path()
        var descent = Path()

        var previousPoint = CGPoint(x: 0, y: midY)
        for i in 0..<values.count {
            let x = CGFloat(i) * stepWidth
            let y = midY - CGFloat(values[i] / maxAbs) * height
            let point = CGPoint(x: x, y: y)

            // Start a new subpath if needed
            if i == 0 {
                previousPoint = point
                continue
            }

            // Build tiny trapezoids between previous and current segment against baseline
            let polyline = (previousPoint, point)

            // If the segment is entirely above baseline → add to climb
            if polyline.0.y <= midY && polyline.1.y <= midY {
                var p = Path()
                p.move(to: CGPoint(x: polyline.0.x, y: midY))
                p.addLine(to: polyline.0)
                p.addLine(to: polyline.1)
                p.addLine(to: CGPoint(x: polyline.1.x, y: midY))
                p.closeSubpath()
                climb.addPath(p)
            }
            // Entirely below → descent
            else if polyline.0.y >= midY && polyline.1.y >= midY {
                var p = Path()
                p.move(to: CGPoint(x: polyline.0.x, y: midY))
                p.addLine(to: polyline.0)
                p.addLine(to: polyline.1)
                p.addLine(to: CGPoint(x: polyline.1.x, y: midY))
                p.closeSubpath()
                descent.addPath(p)
            }
            // Segment crosses baseline → split on midY for accurate fill
            else {
                let t = lineIntersectionT(a: polyline.0, b: polyline.1, y: midY)
                let crossX = polyline.0.x + (polyline.1.x - polyline.0.x) * t
                let cross = CGPoint(x: crossX, y: midY)

                // First partial
                if polyline.0.y < midY {
                    var p = Path()
                    p.move(to: CGPoint(x: polyline.0.x, y: midY))
                    p.addLine(to: polyline.0)
                    p.addLine(to: cross)
                    p.closeSubpath()
                    climb.addPath(p)
                } else {
                    var p = Path()
                    p.move(to: CGPoint(x: polyline.0.x, y: midY))
                    p.addLine(to: polyline.0)
                    p.addLine(to: cross)
                    p.closeSubpath()
                    descent.addPath(p)
                }

                // Second partial
                if polyline.1.y < midY {
                    var p = Path()
                    p.move(to: cross)
                    p.addLine(to: polyline.1)
                    p.addLine(to: CGPoint(x: polyline.1.x, y: midY))
                    p.closeSubpath()
                    climb.addPath(p)
                } else {
                    var p = Path()
                    p.move(to: cross)
                    p.addLine(to: polyline.1)
                    p.addLine(to: CGPoint(x: polyline.1.x, y: midY))
                    p.closeSubpath()
                    descent.addPath(p)
                }
            }

            previousPoint = point
        }

        return (climb, descent)
    }

    // MARK: Marker

    private func scrubMarker(in size: CGSize, progress: Double) -> some View {
        let x = clamp(progress, 0, 1) * size.width
        return VStack(spacing: 2) {
            Rectangle()
                .fill(Color.primary.opacity(0.25))
                .frame(width: 1.0)
                .frame(maxHeight: .infinity)
                .overlay(Rectangle().fill(Color.primary.opacity(0.55)).frame(width: 0.5))
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
                .offset(x: x - 3, y: size.height / 2 - 3) // center on the baseline initially
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.clear).frame(width: x, height: 1) // align leading
        }
    }

    // MARK: Accessibility

    private func accessibilitySummary() -> String {
        guard let summary, !summary.stepGrades.isEmpty else {
            return "Elevation profile unavailable"
        }
        let maxUp = Int((summary.stepGrades.max() ?? 0).rounded())
        let maxDown = Int((summary.stepGrades.min() ?? 0).rounded())
        if maxUp <= 0 && maxDown >= 0 {
            return "Flat route"
        }
        if maxDown < 0 {
            return "Elevation profile. Max climb \(maxUp) percent. Max descent \(abs(maxDown)) percent."
        }
        return "Elevation profile. Max climb \(maxUp) percent."
    }

    // MARK: Math helpers

    private func lineIntersectionT(a: CGPoint, b: CGPoint, y: CGFloat) -> CGFloat {
        let dy = b.y - a.y
        guard abs(dy) > .ulpOfOne else { return 0 }
        return (y - a.y) / dy
    }

    private func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T {
        max(lo, min(hi, v))
    }
}


