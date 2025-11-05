// Features/Map/Views/ElevationProfileView.swift
import SwiftUI

public struct ElevationProfileView: View {
    private let summary: GradeSummary?

    public init(summary: GradeSummary?) {
        self.summary = summary
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Elevation")
                    .font(.headline)
                Spacer()
                if let summary {
                    Text(String(format: "Max %.0f%%", summary.maxGrade))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            GeometryReader { proxy in
                ZStack {
                    baseline(in: proxy.size)
                        .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    profilePath(in: proxy.size)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                    if (summary?.stepGrades ?? []).allSatisfy({ abs($0) < 0.1 }) {
                        Text("Flat route")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 84)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemBackground)))
        }
    }

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
        let height = size.height / 2 - 6
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
}
