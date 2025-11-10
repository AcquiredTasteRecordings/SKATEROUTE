// Services/Voice/SpeechCueEngine.swift
// Voice for navigation turn cues. Interruptible, language-aware, haptics-aware.
// Zero tracking. Plugs into RouteService/TurnCueEngine. Test-friendly seams.

import Foundation
import AVFoundation
import Combine
import CoreHaptics
import os.log

// MARK: - Cue contracts (keep in sync with Route/Turn cue models)

public enum CuePriority: Int, Codable, CaseIterable {
    case low = 0        // e.g., “continue straight”
    case normal = 1     // e.g., “slight right in 100 m”
    case high = 2       // e.g., “turn left now”
    case critical = 3   // e.g., “off route”, “hazard ahead”
}

/// Minimal cue payload SpeechCueEngine needs. Your TurnCueEngine should map into this.
public struct SpeechCue: Equatable, Hashable {
    public let id: String
    public let text: String                  // fully formatted, localized
    public let localeHint: Locale?           // optional per-cue hint (e.g., street names in Spanish)
    public let priority: CuePriority
    public let hapticStyle: HapticStyle
    public let shouldInterruptLowerPriority: Bool
    public let createdAt: Date

    public init(id: String = UUID().uuidString,
                text: String,
                localeHint: Locale? = nil,
                priority: CuePriority = .normal,
                hapticStyle: HapticStyle = .tick,
                shouldInterruptLowerPriority: Bool = true,
                createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.localeHint = localeHint
        self.priority = priority
        self.hapticStyle = hapticStyle
        self.shouldInterruptLowerPriority = shouldInterruptLowerPriority
        self.createdAt = createdAt
    }
}

/// Haptic intent. Engine chooses the best available hardware pattern.
public enum HapticStyle: String, Codable, CaseIterable {
    case none, tick, prompt, warning, success
}

// MARK: - DI seams

public protocol SpeechCueProducing: AnyObject {
    func start()
    func stop()
    func pause()
    func resume()

    /// Enqueue a cue; engine dedupes and schedules speech + haptics.
    func enqueue(_ cue: SpeechCue)

    /// Clear any pending non-spoken cues and optionally stop current speech.
    func clear(stopSpeaking: Bool)

    /// Off-route toggle: critical “recalculation” cues preempt others.
    func setOffRoute(_ offRoute: Bool)

    /// Hooks for UI
    var isSpeakingPublisher: AnyPublisher<Bool, Never> { get }
    var lastSpokenCuePublisher: AnyPublisher<SpeechCue?, Never> { get }
}

// MARK: - Engine

@MainActor
public final class SpeechCueEngine: NSObject, SpeechCueProducing {

    public struct Config: Equatable {
        public var rate: Float = AVSpeechUtteranceDefaultSpeechRate // system appropriate
        public var pitch: Float = 1.0
        public var volume: Float = 1.0
        public var ducking: Bool = true             // mix with others (Maps-like)
        public var allowsAirPlay: Bool = true
        public var cadenceThrottle: TimeInterval = 1.2  // minimum seconds between spoken cues
        public var coalesceWindow: TimeInterval = 0.9   // merge rapidly repeated duplicates
        public var allowOnLockScreen: Bool = true
        public init() {}
    }

    // Public streams
    private let speakingSubject = CurrentValueSubject<Bool, Never>(false)
    public var isSpeakingPublisher: AnyPublisher<Bool, Never> { speakingSubject.eraseToAnyPublisher() }

    private let lastSpokenSubject = CurrentValueSubject<SpeechCue?, Never>(nil)
    public var lastSpokenCuePublisher: AnyPublisher<SpeechCue?, Never> { lastSpokenSubject.eraseToAnyPublisher() }

    // Internals
    private let synth = AVSpeechSynthesizer()
    private let audioSession = AVAudioSession.sharedInstance()
    private let log = Logger(subsystem: "com.skateroute", category: "SpeechCueEngine")

    private var config: Config
    private var queue: [SpeechCue] = []
    private var lastSpokenAt: Date = .distantPast
    private var lastCueFingerprint: (text: String, ts: Date)?

    private var offRoute: Bool = false

    // Haptics
    private var hapticEngine: CHHapticEngine?
    private var deviceSupportsHaptics: Bool {
        (try? CHHapticEngine.capabilitiesForHardware()).map { $0.supportsHaptics } ?? false
    }

    public init(config: Config = .init()) {
        self.config = config
        super.init()
        synth.delegate = self
        setupSession()
        prepareHaptics()
    }

    // MARK: Lifecycle

    public func start() {
        // noop; session is configured; engine is passive until queue has items
    }

    public func stop() {
        clear(stopSpeaking: true)
        speakingSubject.send(false)
        teardownSession()
    }

    public func pause() {
        _ = synth.pauseSpeaking(at: .immediate)
    }

    public func resume() {
        _ = synth.continueSpeaking()
    }

    public func clear(stopSpeaking: Bool) {
        queue.removeAll(keepingCapacity: false)
        if stopSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    // MARK: Off-route policy

    public func setOffRoute(_ offRoute: Bool) {
        self.offRoute = offRoute
        if offRoute {
            // Interrupt anything non-critical; schedule recalculation tone
            synth.stopSpeaking(at: .immediate)
            fireHaptic(.warning)
            // Let TurnCueEngine enqueue a “rerouting” cue; we won’t create text here to keep separation of concerns.
        }
    }

    // MARK: Enqueue

    public func enqueue(_ cue: SpeechCue) {
        // Coalesce: if same text recently scheduled/spoken, drop it
        if let fp = lastCueFingerprint,
           cue.text == fp.text,
           Date().timeIntervalSince(fp.ts) < config.coalesceWindow {
            return
        }

        // Priority handling: if current speaking is lower priority and cue wants interrupt, stop
        if synth.isSpeaking,
           cue.shouldInterruptLowerPriority,
           let currentPriority = currentUtterancePriority(),
           cue.priority.rawValue > currentPriority.rawValue {
            synth.stopSpeaking(at: .immediate)
        }

        // Insert by priority (stable)
        insertCueSorted(cue)

        // Try to speak if idle or after throttle window
        speakNextIfReady()
    }

    // MARK: Private scheduling

    private func insertCueSorted(_ cue: SpeechCue) {
        if queue.isEmpty { queue.append(cue); return }
        var inserted = false
        for i in 0..<queue.count where !inserted {
            if cue.priority.rawValue > queue[i].priority.rawValue {
                queue.insert(cue, at: i)
                inserted = true
            }
        }
        if !inserted { queue.append(cue) }
    }

    private func speakNextIfReady() {
        guard !synth.isSpeaking else { return }
        guard let next = queue.first else { return }

        // Don’t speak normal/low cues while off-route; let reroute/critical cues go through.
        if offRoute && next.priority.rawValue < CuePriority.high.rawValue {
            // Keep them queued but don’t speak yet
            return
        }

        // Throttle cadence
        let elapsed = Date().timeIntervalSince(lastSpokenAt)
        if elapsed < config.cadenceThrottle {
            let delay = config.cadenceThrottle - elapsed
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.speakNextIfReady() }
            return
        }

        queue.removeFirst()

        // Build utterance with language fallback
        let utterance = makeUtterance(for: next)

        // Fire haptics just before speaking to align
        fireHaptic(next.hapticStyle)

        // Speak
        speakingSubject.send(true)
        lastCueFingerprint = (text: next.text, ts: Date())
        lastSpokenSubject.send(next)
        synth.speak(utterance)
        lastSpokenAt = Date()
    }

    private func makeUtterance(for cue: SpeechCue) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: cue.text)
        let lang = bestLanguage(for: cue.localeHint)
        u.voice = AVSpeechSynthesisVoice(language: lang)
        u.rate = config.rate
        u.pitchMultiplier = config.pitch
        u.volume = config.volume
        // Slight pre/post delay to avoid stepping on haptics/system voice
        u.preUtteranceDelay = 0.02
        u.postUtteranceDelay = 0.02
        return u
    }

    // MARK: Language resolution

    private func bestLanguage(for hint: Locale?) -> String {
        // 1) Explicit cue hint
        if let code = hint?.identifier, AVSpeechSynthesisVoice(language: code) != nil { return code }
        // 2) System preferred languages
        for code in Locale.preferredLanguages {
            if AVSpeechSynthesisVoice(language: code) != nil { return code }
        }
        // 3) English fallback (widest availability)
        return "en-US"
    }

    private func currentUtterancePriority() -> CuePriority? {
        // We can’t read priority from AVSpeechUtterance directly; track via lastSpokenCuePublisher if needed by caller.
        lastSpokenSubject.value?.priority
    }

    // MARK: Audio session policy

    private func setupSession() {
        do {
            try audioSession.setCategory(.playback,
                                         mode: .voicePrompt,
                                         options: config.ducking ? [.duckOthers, .mixWithOthers, .allowBluetoothA2DP, .allowAirPlay] : [.mixWithOthers])
            if config.allowOnLockScreen {
                try audioSession.setActive(true, options: [.notifyOthersOnDeactivation])
            } else {
                try audioSession.setActive(true)
            }
        } catch {
            log.error("AVAudioSession error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func teardownSession() {
        do { try audioSession.setActive(false) } catch {}
    }

    // MARK: Haptics

    private func prepareHaptics() {
        guard deviceSupportsHaptics else { return }
        do {
            hapticEngine = try CHHapticEngine()
            try hapticEngine?.start()
        } catch {
            hapticEngine = nil
            log.notice("Haptics unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fireHaptic(_ style: HapticStyle) {
        guard style != .none else { return }

        if let engine = hapticEngine {
            do {
                let pattern: CHHapticPattern
                switch style {
                case .tick:
                    pattern = try CHHapticPattern(events: [
                        CHHapticEvent(eventType: .hapticTransient, parameters: [], relativeTime: 0)
                    ], parameters: [])
                case .prompt:
                    pattern = try CHHapticPattern(events: [
                        CHHapticEvent(eventType: .hapticTransient, parameters: [], relativeTime: 0),
                        CHHapticEvent(eventType: .hapticTransient, parameters: [], relativeTime: 0.12)
                    ], parameters: [])
                case .warning:
                    pattern = try CHHapticPattern(events: [
                        CHHapticEvent(eventType: .hapticContinuous,
                                      parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8),
                                                   CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)],
                                      relativeTime: 0, duration: 0.25)
                    ], parameters: [])
                case .success:
                    pattern = try CHHapticPattern(events: [
                        CHHapticEvent(eventType: .hapticTransient, parameters: [], relativeTime: 0),
                        CHHapticEvent(eventType: .hapticTransient, parameters: [], relativeTime: 0.08),
                        CHHapticEvent(eventType: .hapticTransient, parameters: [], relativeTime: 0.16)
                    ], parameters: [])
                case .none:
                    return
                }
                let player = try engine.makePlayer(with: pattern)
                try engine.start()
                try player.start(atTime: 0)
            } catch {
                // Silent fallback to light impact
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        } else {
            // Fallback to UIFeedback if CoreHaptics not available
            switch style {
            case .tick: UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case .prompt: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .none: break
            }
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechCueEngine: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        speakingSubject.send(true)
    }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        speakingSubject.send(false)
        // Move to next if any
        speakNextIfReady()
    }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        speakingSubject.send(false)
        // After interruption, re-attempt next (queue may have new high-priority cues)
        speakNextIfReady()
    }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        speakingSubject.send(false)
    }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        speakingSubject.send(true)
    }
}

// MARK: - DEBUG Fakes (for unit tests)

#if DEBUG
public final class SpeechCueEngineFake: SpeechCueProducing {
    public private(set) var started = false
    public private(set) var paused = false
    public private(set) var received: [SpeechCue] = []

    private let speaking = CurrentValueSubject<Bool, Never>(false)
    private let last = CurrentValueSubject<SpeechCue?, Never>(nil)

    public var isSpeakingPublisher: AnyPublisher<Bool, Never> { speaking.eraseToAnyPublisher() }
    public var lastSpokenCuePublisher: AnyPublisher<SpeechCue?, Never> { last.eraseToAnyPublisher() }

    public func start() { started = true }
    public func stop() { started = false; received.removeAll(); speaking.send(false) }
    public func pause() { paused = true; speaking.send(false) }
    public func resume() { paused = false; speaking.send(true) }
    public func enqueue(_ cue: SpeechCue) { received.append(cue); last.send(cue) }
    public func clear(stopSpeaking: Bool) { received.removeAll(); if stopSpeaking { speaking.send(false) } }
    public func setOffRoute(_ offRoute: Bool) {}
}
#endif

// MARK: - Integration guide (summary)
// • Resolve the engine in AppDI as a singleton.
// • TurnCueEngine (or MapScreen VM) should translate upcoming route instructions into `SpeechCue`
//   with localized text and appropriate `priority` (e.g., `.high` for “turn now”, `.critical` for “off route”).
// • On “off-route” detection: call `setOffRoute(true)` and enqueue your reroute cue; when back on-route, set `false`.
// • In UI: subscribe to `isSpeakingPublisher` and `lastSpokenCuePublisher` for HUD affordances (e.g., a speaking indicator).
// • Respect user mute: gate `enqueue` behind a user preference toggle; do not mutate system volume.
