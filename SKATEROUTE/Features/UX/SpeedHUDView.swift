// Features/UX/SpeedHUDView.swift
// Accessible, motion-aware speed tile with threshold cues and clean haptics.
// Consistent with RideTelemetryHUD + HapticCue, Dynamic Type–safe, and battery-light.

import SwiftUI
import UIKit

public struct SpeedHUDView: View {
    // MARK: - Inputs
    @Binding public var speedKmh: Double

    public struct Config: Sendable, Equatable {
        /// Enter "moderate" at/above this speed (km/h).
        public var moderateThreshold: Double = 10
        /// Enter "fast" at/above this speed (km/h).
        public var fastThreshold: Double = 25
        /// Enable pulse animation when in "fast".
        public var enablePulse: Bool = true
        /// Optional smoothing (0…1, higher = snappier). 0 disables.
        public var smoothingAlpha: Double = 0.25
        /// Show a thin status ring using the state color.
        public var showRing: Bool = true
        public init() {}
    }

    private let cfg: Config

    // MARK: - Environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Local state
    @State private var filteredSpeed: Double = 0
    @State private var isPulsing = false
    @State private var previousState: SpeedState = .cruising

    public init(speedKmh: Binding<Double>, config: Config = .init()) {
        self._speedKmh = speedKmh
        self.cfg = config
    }

    // MARK: - View
    public var body: some View {
        let state = speedState(filteredSpeed)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(speedString(filteredSpeed))
                    .font(.system(size: 40, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText()) // smooth value swaps
                    .foregroundStyle(stateColor(state))
                    .accessibilityLabel("Current speed")
                    .accessibilityValue(accessibilitySpeed(filteredSpeed))
                Text(unitString)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(stateLabel(state))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            if cfg.showRing {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(stateColor(state).opacity(0.9), lineWidth: 2)
                    .animation(.easeInOut(duration: 0.2), value: state)
            }
        }
        .scaleEffect(isPulsing ? 1.06 : 1.0)
        .animation(
            (shouldPulse(state) ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default),
            value: isPulsing
        )
        .onAppear {
            filteredSpeed = speedKmh
            previousState = state
            isPulsing = shouldPulse(state)
        }
        .onChange(of: speedKmh) { _, new in
            // Lightweight EMA smoothing for readability (battery-light).
            if cfg.smoothingAlpha > 0 {
                let a = min(max(cfg.smoothingAlpha, 0), 1)
                filteredSpeed = a * new + (1 - a) * filteredSpeed
            } else {
                filteredSpeed = new
            }
        }
        .onChange(of: state) { _, newState in
            if newState != previousState {
                provideHaptics(for: newState)
                announceIfNeeded(newState, speed: filteredSpeed)
                previousState = newState
            }
            isPulsing = shouldPulse(newState)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("SpeedHUDView")
    }
}

// MARK: - Logic

private enum SpeedState { case cruising, moderate, fast }

private extension SpeedHUDView {
    func speedState(_ kmh: Double) -> SpeedState {
        if kmh >= cfg.fastThreshold { return .fast }
        if kmh >= cfg.moderateThreshold { return .moderate }
        return .cruising
    }

    func shouldPulse(_ state: SpeedState) -> Bool {
        cfg.enablePulse && !reduceMotion && state == .fast
    }

    func stateColor(_ state: SpeedState) -> Color {
        switch state {
        case .cruising: return .green
        case .moderate: return .yellow
        case .fast:     return .red
        }
    }

    func stateLabel(_ state: SpeedState) -> String {
        switch state {
        case .cruising: return NSLocalizedString("Cruising", comment: "speed state")
        case .moderate: return NSLocalizedString("Rolling", comment: "speed state")
        case .fast:     return NSLocalizedString("Fast", comment: "speed state")
        }
    }

    func speedString(_ kmh: Double) -> String {
        let v = max(0, kmh)
        // 0–9.9 show one decimal, otherwise whole number
        return String(format: v < 9.95 ? "%.1f" : "%.0f", v)
    }

    var unitString: String { "km/h" }

    func accessibilitySpeed(_ kmh: Double) -> String {
        let v = Int(round(max(0, kmh)))
        return "\(v) kilometers per hour"
    }

    func provideHaptics(for state: SpeedState) {
        // Unified haptics, aligned with the app’s HapticCue.
        switch state {
        case .cruising: HapticCue.success()
        case .moderate: HapticCue.selection()
        case .fast:     HapticCue.warning()
        }
    }

    func announceIfNeeded(_ state: SpeedState, speed: Double) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        let msg = "\(stateLabel(state)). \(accessibilitySpeed(speed))"
        UIAccessibility.post(notification: .announcement, argument: msg)
    }
}

// MARK: - Preview

#if DEBUG
struct SpeedHUDView_Previews: PreviewProvider {
    struct Host: View {
        @State var v: Double = 12.3
        var body: some View {
            VStack(spacing: 16) {
                SpeedHUDView(speedKmh: $v)
                HStack {
                    Button("8 km/h") { v = 8 }
                    Button("16 km/h") { v = 16 }
                    Button("28 km/h") { v = 28 }
                }
            }
            .padding()
            .background(Color.black.opacity(0.95))
            .preferredColorScheme(.dark)
        }
    }
    static var previews: some View { Host() }
}
#endif


