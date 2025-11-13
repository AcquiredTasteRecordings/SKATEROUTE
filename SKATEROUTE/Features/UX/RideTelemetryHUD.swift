// Features/UX/RideTelemetryHUD.swift
// Lightweight, battery-friendly HUD for live navigation.
// Binds to RideRecorder + TurnCueEngine, with accessible, glanceable stats.

import SwiftUI
import MapKit
import CoreLocation
import Combine
import UIKit

public struct RideTelemetryHUD: View {
    // MARK: - Dependencies
    @ObservedObject private var recorder: RideRecorder
    @ObservedObject private var cueEngine: TurnCueEngine

    // MARK: - Config
    public struct Config {
        public var showETA: Bool = true
        public var showGPS: Bool = true
        public var showCoastGauge: Bool = true
        public var emphasizeSpeed: Bool = true
        public var accentColor: Color = .mint
        public init() {}
    }
    private let cfg: Config

    // MARK: - Init
    public init(recorder: RideRecorder, cueEngine: TurnCueEngine, config: Config = .init()) {
        self.recorder = recorder
        self.cueEngine = cueEngine
        self.cfg = config
    }

    // MARK: - Body
    public var body: some View {
        VStack(spacing: 10) {
            cueBanner
            metricsStrip
            if cfg.showCoastGauge { coastGauge }
            if cfg.showGPS { gpsRow }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("RideTelemetryHUD.Root")
    }

    // MARK: - Cue Banner
    private var cueBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: cueSymbol(cueEngine.latestCue))
                .imageScale(.large)
                .font(.title2.weight(.semibold))
                .foregroundStyle(cueTierColor(cueEngine.latestCue?.tier))

            VStack(alignment: .leading, spacing: 2) {
                Text(cueTitle(cueEngine.latestCue))
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                if let dist = cueDistanceText(cueEngine.latestCue) {
                    Text(dist)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Distance to maneuver \(dist)")
                }
            }
            Spacer()

            // End Ride control (safety: confirms with a long-press)
            Button {
                // noop; require long press to prevent fat finger stops
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
            }
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.8).onEnded { _ in
                hapticWarning()
                recorder.stop()
            })
            .accessibilityLabel("End ride")
            .accessibilityHint("Long press to stop")
        }
        .padding(.top, 2)
        .accessibilityIdentifier("RideTelemetryHUD.CueBanner")
    }

    // MARK: - Metrics
    private var metricsStrip: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            // Speed (primary)
            VStack(alignment: .leading, spacing: 0) {
                Text(speedText(recorder.speedKmh))
                    .font(cfg.emphasizeSpeed ? .system(size: 36, weight: .black, design: .rounded)
                                             : .title2.weight(.heavy))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .frame(minWidth: 88, alignment: .leading)
                    .foregroundStyle(.primary)
                Text("km/h")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Speed \(speedText(recorder.speedKmh)) kilometers per hour")

            Divider().frame(height: 28).opacity(0.15)

            // Distance
            VStack(alignment: .leading, spacing: 2) {
                Text(distanceText(recorder.distanceMeters))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.primary)
                Text("Distance")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Distance \(distanceText(recorder.distanceMeters))")

            // Elapsed
            VStack(alignment: .leading, spacing: 2) {
                Text(timeText(recorder.elapsed))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.primary)
                Text("Elapsed")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Elapsed \(timeText(recorder.elapsed))")

            if cfg.showETA {
                VStack(alignment: .leading, spacing: 2) {
                    Text(etaText())
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.primary)
                    Text("ETA")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Estimated arrival \(etaText())")
            }

            Spacer(minLength: 6)
        }
        .accessibilityIdentifier("RideTelemetryHUD.Metrics")
    }

    // MARK: - Coast Gauge
    private var coastGauge: some View {
        let ratio = max(0, min(1, recorder.coastRatio))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Coast")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(coastPercentText(ratio))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.18))
                    RoundedRectangle(cornerRadius: 6)
                        .fill(cfg.accentColor.gradient)
                        .frame(width: max(0, geo.size.width * ratio))
                        .animation(.easeOut(duration: 0.25), value: ratio)
                }
            }
            .frame(height: 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Coasting ratio \(coastPercentText(ratio))")
        }
        .accessibilityIdentifier("RideTelemetryHUD.CoastGauge")
    }

    // MARK: - GPS Row
    private var gpsRow: some View {
        let accuracy = recorder.lastLocation?.horizontalAccuracy ?? -1
        let text = gpsAccuracyText(accuracy)
        let color = gpsColor(accuracy)
        return HStack(spacing: 8) {
            Image(systemName: "location.circle.fill")
                .foregroundStyle(color)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let ts = recorder.lastLocation?.timestamp {
                Text(relativeTime(ts))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Last fix \(relativeTime(ts)) ago")
            }
        }
        .accessibilityIdentifier("RideTelemetryHUD.GPS")
    }

    // MARK: - Helpers (Formatting)
    private func speedText(_ kmh: Double) -> String {
        let v = max(0, kmh)
        return String(format: v < 9.95 ? "%.1f" : "%.0f", v)
    }

    private func distanceText(_ meters: Double) -> String {
        if meters < 950 { return String(format: "%.0f m", meters) }
        return String(format: "%.1f km", meters / 1000.0)
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func etaText() -> String {
        guard let route = recorder.currentRoute else { return "—" }
        // Heuristic ETA: remaining = route.expected - elapsed, min floor 1m
        let remain = max(60, route.expectedTravelTime - recorder.elapsed)
        let s = Int(remain)
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func coastPercentText(_ ratio: Double) -> String {
        let pct = Int((ratio * 100).rounded())
        return "\(pct)%"
    }

    private func gpsAccuracyText(_ meters: CLLocationAccuracy) -> String {
        guard meters >= 0 else { return "GPS: —" }
        switch meters {
        case ..<8: return "GPS: High (\(Int(meters)) m)"
        case 8..<25: return "GPS: Medium (\(Int(meters)) m)"
        default: return "GPS: Low (\(Int(meters)) m)"
        }
    }

    private func gpsColor(_ meters: CLLocationAccuracy) -> Color {
        guard meters >= 0 else { return .secondary }
        if meters < 8 { return .green }
        if meters < 25 { return .yellow }
        return .orange
    }

    private func cueTitle(_ cue: TurnCue?) -> String {
        guard let cue else { return "Getting route…" }
        return cue.instruction
    }

    private func cueDistanceText(_ cue: TurnCue?) -> String? {
        guard let cue, cue.tier != .arrived else { return nil }
        let m = cue.distanceMeters
        if m <= 0 { return nil }
        if m < 950 { return "\(Int(m)) m" }
        return String(format: "%.1f km", m / 1000.0)
    }

    private func cueSymbol(_ cue: TurnCue?) -> String {
        guard let cue else { return "arrow.up" }
        return cue.iconName
    }

    private func cueTierColor(_ tier: CueTier?) -> Color {
        switch tier {
        case .far: return .primary
        case .near: return .yellow
        case .now: return .orange
        case .arrived: return .green
        case .none: return .secondary
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let delta = max(0, Date().timeIntervalSince(date))
        if delta < 1.5 { return "now" }
        if delta < 60 { return "\(Int(delta))s" }
        let m = Int(delta / 60)
        return "\(m)m"
    }

    private func hapticWarning() {
        // Local minimal haptic to avoid cross-file dependency
        #if os(iOS)
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(.warning)
        #endif
    }
}

// MARK: - Preview

#if DEBUG
struct RideTelemetryHUD_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Ride Telemetry HUD")
                    .foregroundColor(.white)
                    .font(.headline)
                Text("Preview stub (no live data)")
                    .foregroundColor(.secondary)
                // In the real app, this HUD will be constructed with a live RideRecorder + TurnCueEngine from AppDI.
            }
            .padding()
        }
        .previewLayout(.sizeThatFits)
    }
}
#endif
