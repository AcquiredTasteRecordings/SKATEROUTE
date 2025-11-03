// Features/UX/TurnCueEngine.swift
import Foundation
import CoreLocation
import MapKit
import AVFoundation
import UIKit

/// Enum to configure the style of turn cues.
public enum TurnCueStyle {
    /// Both beep and haptic feedback.
    case standard
    /// Only vibrate/haptic.
    case vibrateOnly
    /// Only beep sound.
    case beepOnly
    /// No cues (silent).
    case silent
}

/// Generates haptic, audio, and voice cues for upcoming turns.
/// - Provides customizable feedback style and rate-limiting.
/// - Adjusts haptic feedback based on turn sharpness.
/// - Announces turn directions via VoiceOver if enabled.
@MainActor
public final class TurnCueEngine: NSObject, ObservableObject {
    /// The current route being navigated.
    private var route: MKRoute?
    /// The index of the next step to cue.
    private var currentStepIndex: Int = 0
    /// Haptic feedback generator.
    private var feedback = UINotificationFeedbackGenerator()
    /// Used for playing beeps.
    private var player: AVAudioPlayer?
    /// Used for voice announcements.
    private let speechSynthesizer = AVSpeechSynthesizer()
    /// The style of cue to use.
    public var cueStyle: TurnCueStyle = .standard
    /// The minimum interval (seconds) between cues.
    private let cueInterval: TimeInterval = 5
    /// The last time a cue was triggered.
    private var lastCueTime: Date?

    /// Prepares the engine with a new route.
    /// - Parameter route: The route to follow.
    public func prepare(route: MKRoute) {
        self.route = route
        self.currentStepIndex = 0
        feedback.prepare()
        lastCueTime = nil
    }

    /// Call periodically as user location updates.
    /// - Parameter current: The user's current location.
    public func tick(current: CLLocation) {
        guard let route = route else { return }
        let steps = route.steps
        guard currentStepIndex < steps.count else { return }

        let step = steps[currentStepIndex]
        let dist = current.distance(from: step.polyline.coordinateLocation())
        if dist < 30 {
            triggerCue(for: step)
            currentStepIndex += 1
        }
    }

    /// Triggers a turn cue (haptic/audio/voice) for the given step, respecting the cue style and rate-limiting.
    /// - Parameter step: The route step to cue.
    private func triggerCue(for step: MKRoute.Step) {
        // Rate limiting: ensure cues do not occur more than once every `cueInterval` seconds.
        let now = Date()
        if let last = lastCueTime, now.timeIntervalSince(last) < cueInterval {
            return
        }
        lastCueTime = now

        // Ensure feedback and audio are performed on main thread.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Determine if VoiceOver is running for accessibility.
            let isVoiceOver = UIAccessibility.isVoiceOverRunning
            if isVoiceOver {
                self.announceStep(step)
            }

            switch self.cueStyle {
            case .standard:
                self.performHaptic(for: step)
                self.playBeep()
            case .vibrateOnly:
                self.performHaptic(for: step)
            case .beepOnly:
                self.playBeep()
            case .silent:
                break
            }
            print("Turn cue: \(step.instructions)")
        }
    }

    /// Plays a system beep sound.
    private func playBeep() {
        // Use system sound. 1104 is the "Tock" sound.
        AudioServicesPlaySystemSound(1104)
    }

    /// Performs haptic feedback, customizing sharpness for left/right turns.
    /// - Parameter step: The route step to cue.
    private func performHaptic(for step: MKRoute.Step) {
        // Attempt to parse the instruction for left/right/straight and sharpness.
        let instruction = step.instructions.lowercased()
        if instruction.contains("sharp left") {
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.error)
        } else if instruction.contains("left") {
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.prepare()
            generator.impactOccurred()
        } else if instruction.contains("sharp right") {
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.warning)
        } else if instruction.contains("right") {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.prepare()
            generator.impactOccurred()
        } else {
            // For straight or unknown, use light feedback.
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.prepare()
            generator.impactOccurred()
        }
    }

    /// Announces the turn direction using VoiceOver (if enabled).
    /// - Parameter step: The route step to announce.
    private func announceStep(_ step: MKRoute.Step) {
        let utterance = AVSpeechUtterance(string: step.instructions)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
        speechSynthesizer.speak(utterance)
    }
}

/// Convenience extension to get the first coordinate as CLLocation.
private extension MKPolyline {
    /// Returns the first coordinate of the polyline as a CLLocation.
    func coordinateLocation() -> CLLocation {
        let c = coordinates().first ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
        return CLLocation(latitude: c.latitude, longitude: c.longitude)
    }
}
