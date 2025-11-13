// Features/UX/HapticCue.swift
// Unified haptics: Core Haptics first, UIFeedback fallback.
// Maps navigation cues → tactile patterns, with rate-limit + lifecycle management.

import Foundation
import UIKit
import CoreHaptics

/// High-level haptic intents used across the app.
/// Keep this small and reusable; we map navigation and UI events onto these.
public enum HapticIntent: Equatable {
    case softTap                 // generic light tap (UI)
    case firmTap                 // heavier confirm
    case selection               // picker/segmented control
    case success                 // operation succeeded
    case warning                 // caution
    case error                   // failure
    case navFar                  // “heads up” for far turn cue
    case navNear                 // “get ready” cue
    case navNow                  // “do it now” cue
    case arrived                 // arrival celebration
}

/// Centralized haptic driver.
/// - Uses Core Haptics when available (richer patterns), else falls back to UIFeedbackGenerators.
/// - Rate-limits to prevent spam.
/// - Automatically handles app lifecycle (suspends on background).
public final class HapticCue {

    // MARK: Singleton
    public static let shared = HapticCue()

    // MARK: Engine (Core Haptics)
    private var engine: CHHapticEngine?
    private var supportsHaptics: Bool = false

    // Small cache of compiled patterns
    private var patternCache: [HapticIntent: CHHapticPattern] = [:]

    // Fallback generators
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private let selectGen   = UISelectionFeedbackGenerator()
    private let notifyGen   = UINotificationFeedbackGenerator()

    // Anti-spam
    private var lastFire: Date = .distantPast
    private let minInterval: TimeInterval = 0.070

    // MARK: Init
    private init() {
        prepareEngine()
        observeLifecycle()
    }

    // MARK: Public API

    /// Fire a generic intent.
    public func play(_ intent: HapticIntent) {
        guard canFire() else { return }

        if supportsHaptics, let engine {
            do {
                let pattern = try pattern(for: intent)
                let player = try engine.makePlayer(with: pattern)
                try engine.start()
                try player.start(atTime: CHHapticTimeImmediate)
            } catch {
                // Fallback to UIFeedback
                fallback(intent)
            }
        } else {
            fallback(intent)
        }
    }

    /// Convenience mapping from a turn cue to a haptic.
    public func play(for cue: TurnCue) {
        switch cue.tier {
        case .far:      play(.navFar)
        case .near:     play(.navNear)
        case .now:      play(.navNow)
        case .arrived:  play(.arrived)
        }
    }

    /// Pre-warm the engine before rapid sequences (optional).
    public func prewarm() {
        guard supportsHaptics else { return }
        try? engine?.start()
        // A tiny silent transient helps prime Taptic for lower latency.
        _ = try? engine?.makePlayer(with: CHHapticPattern(events: [], parameters: []))
    }

    // MARK: - Private

    private func prepareEngine() {
        supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        guard supportsHaptics else { return }

        do {
            engine = try CHHapticEngine()
            engine?.stoppedHandler = { [weak self] reason in
                // Try to rebuild engine on server restart or interruption end
                if reason == .audioSessionInterrupt || reason == .applicationSuspended {
                    // No-op; will re-start on next play
                } else {
                    self?.engine = try? CHHapticEngine()
                }
            }
            engine?.resetHandler = { [weak self] in
                self?.engine = try? CHHapticEngine()
            }
            try engine?.start() // warm
            engine?.notifyWhenPlayersFinished { _ in .stopEngine }
        } catch {
            supportsHaptics = false
            engine = nil
        }
    }

    private func observeLifecycle() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Stop to save power; engine will relaunch on next play.
            self?.engine?.stop(completionHandler: nil)
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Lazy start on demand; no need to auto start here.
            _ = self // keep weak self captured
        }
    }

    private func canFire() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastFire) >= minInterval else { return false }
        lastFire = now
        return true
    }

    private func fallback(_ intent: HapticIntent) {
        switch intent {
        case .softTap:          impactLight.prepare(); impactLight.impactOccurred()
        case .firmTap:          impactHeavy.prepare(); impactHeavy.impactOccurred()
        case .selection:        selectGen.prepare();   selectGen.selectionChanged()
        case .success:          notifyGen.prepare();   notifyGen.notificationOccurred(.success)
        case .warning:          notifyGen.prepare();   notifyGen.notificationOccurred(.warning)
        case .error:            notifyGen.prepare();   notifyGen.notificationOccurred(.error)
        case .navFar:           impactLight.prepare(); impactLight.impactOccurred(intensity: 0.4)
        case .navNear:          impactLight.prepare(); impactLight.impactOccurred(intensity: 0.7)
        case .navNow:           impactHeavy.prepare(); impactHeavy.impactOccurred(intensity: 1.0)
        case .arrived:          notifyGen.prepare();   notifyGen.notificationOccurred(.success)
        }
    }

    // MARK: Pattern factory (Core Haptics)

    private func pattern(for intent: HapticIntent) throws -> CHHapticPattern {
        if let cached = patternCache[intent] { return cached }

        let p: CHHapticPattern
        switch intent {
        case .softTap:
            p = try transient(intensity: 0.4, sharpness: 0.35)
        case .firmTap:
            p = try transient(intensity: 0.9, sharpness: 0.6)
        case .selection:
            p = try transient(intensity: 0.5, sharpness: 0.4)
        case .success:
            p = try successTriad()
        case .warning:
            p = try doubleBeat(intensity: 0.8, spacing: 0.08)
        case .error:
            p = try descendingBuzz()
        case .navFar:
            p = try transient(intensity: 0.35, sharpness: 0.25)
        case .navNear:
            p = try ramp(intensityFrom: 0.4, to: 0.7, duration: 0.08)
        case .navNow:
            p = try ramp(intensityFrom: 0.6, to: 1.0, duration: 0.12)
        case .arrived:
            p = try successTriad()
        }

        patternCache[intent] = p
        return p
    }

    // MARK: Pattern building blocks

    /// Single transient tap.
    private func transient(intensity: Float, sharpness: Float) throws -> CHHapticPattern {
        let ev = CHHapticEvent(eventType: .hapticTransient,
                               parameters: [
                                   CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                                   CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
                               ],
                               relativeTime: 0)
        return try CHHapticPattern(events: [ev], parameters: [])
    }

    /// Two short beats (warning).
    private func doubleBeat(intensity: Float, spacing: TimeInterval) throws -> CHHapticPattern {
        let e1 = CHHapticEvent(eventType: .hapticTransient,
                               parameters: [
                                   .init(parameterID: .hapticIntensity, value: intensity * 0.9),
                                   .init(parameterID: .hapticSharpness, value: 0.5)
                               ],
                               relativeTime: 0)
        let e2 = CHHapticEvent(eventType: .hapticTransient,
                               parameters: [
                                   .init(parameterID: .hapticIntensity, value: intensity),
                                   .init(parameterID: .hapticSharpness, value: 0.6)
                               ],
                               relativeTime: spacing)
        return try CHHapticPattern(events: [e1, e2], parameters: [])
    }

    /// Quick ramp used for “near/now” navigation cues.
    private func ramp(intensityFrom: Float, to: Float, duration: TimeInterval) throws -> CHHapticPattern {
        let start = CHHapticEvent(eventType: .hapticContinuous,
                                  parameters: [
                                      .init(parameterID: .hapticIntensity, value: intensityFrom),
                                      .init(parameterID: .hapticSharpness, value: 0.6)
                                  ],
                                  relativeTime: 0,
                                  duration: duration)
        let curve = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                .init(relativeTime: 0, value: intensityFrom),
                .init(relativeTime: duration, value: to)
            ],
            relativeTime: 0
        )
        return try CHHapticPattern(events: [start], parameters: [], parameterCurves: [curve])
    }

    /// Little “celebration” triad for success/arrived.
    private func successTriad() throws -> CHHapticPattern {
        let t0: TimeInterval = 0
        let s: TimeInterval = 0.07
        let e1 = CHHapticEvent(eventType: .hapticTransient, parameters: [
            .init(parameterID: .hapticIntensity, value: 0.6),
            .init(parameterID: .hapticSharpness, value: 0.5)
        ], relativeTime: t0)

        let e2 = CHHapticEvent(eventType: .hapticTransient, parameters: [
            .init(parameterID: .hapticIntensity, value: 0.8),
            .init(parameterID: .hapticSharpness, value: 0.7)
        ], relativeTime: t0 + s)

        let e3 = CHHapticEvent(eventType: .hapticTransient, parameters: [
            .init(parameterID: .hapticIntensity, value: 1.0),
            .init(parameterID: .hapticSharpness, value: 0.8)
        ], relativeTime: t0 + 2*s)

        return try CHHapticPattern(events: [e1, e2, e3], parameters: [])
    }

    /// Harsh descending buzz used for errors.
    private func descendingBuzz() throws -> CHHapticPattern {
        let d: TimeInterval = 0.25
        let buzz = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            .init(parameterID: .hapticIntensity, value: 0.9),
            .init(parameterID: .hapticSharpness, value: 0.6)
        ], relativeTime: 0, duration: d)

        let intensityCurve = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                .init(relativeTime: 0, value: 0.9),
                .init(relativeTime: d, value: 0.2)
            ],
            relativeTime: 0
        )
        return try CHHapticPattern(events: [buzz], parameters: [], parameterCurves: [intensityCurve])
    }
}

// MARK: - Sugar

public extension HapticCue {
    static func play(_ intent: HapticIntent) { HapticCue.shared.play(intent) }
    static func play(for cue: TurnCue) { HapticCue.shared.play(for: cue) }

    // Lightweight UI helpers to replace scattered generators:
    static func tap() { play(.softTap) }
    static func light() { play(.softTap) }
    static func firm() { play(.firmTap) }
    static func selection() { play(.selection) }
    static func success() { play(.success) }
    static func warning() { play(.warning) }
    static func error() { play(.error) }
}


