// Features/Map/VoiceToggle.swift
// Quick mute/unmute for turn-by-turn voice guidance.
// - Taps toggle SpeechCueEngine enablement; long-press opens mini sheet for quick options (optional).
// - A11y: VO label “Voice guidance”; announces state change; ≥44pt hit target; Dynamic Type friendly.
// - Persistence: mirrors engine state; engine is the single source of truth (no duplicate prefs here).
// - Privacy: no mic access needed; this only controls TTS output.

import SwiftUI
import Combine
import AVFoundation
import UIKit

// MARK: - DI seam

public protocol SpeechCueControlling: AnyObject {
    var isEnabledPublisher: AnyPublisher<Bool, Never> { get }
    var currentLocaleIdentifier: String { get }
    func setEnabled(_ on: Bool)
    func speakPreviewSampleIfEnabled() // optional nicety (no-op if disabled)
}

// MARK: - ViewModel

@MainActor
public final class VoiceToggleViewModel: ObservableObject {
    @Published public private(set) var isOn: Bool = true
    @Published public var showQuickSheet = false

    private let engine: SpeechCueControlling
    private var cancellables = Set<AnyCancellable>()

    public init(engine: SpeechCueControlling) {
        self.engine = engine
        bind()
    }

    private func bind() {
        engine.isEnabledPublisher
            .receive(on: RunLoop.main)
            .assign(to: &$isOn)
    }

    public func toggle() {
        let next = !isOn
        engine.setEnabled(next)
        announceState(next)
        haptic(next ? .success : .warning)
        if next {
            // Optional tiny sample so rider hears current volume/voice
            engine.speakPreviewSampleIfEnabled()
        }
    }

    private func announceState(_ on: Bool) {
        let msg = on ?
            NSLocalizedString("Voice guidance on", comment: "VO on") :
            NSLocalizedString("Voice guidance off", comment: "VO off")
        UIAccessibility.post(notification: .announcement, argument: msg)
    }

    private func haptic(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(type)
    }
}

// MARK: - View

public struct VoiceToggle: View {
    @ObservedObject private var vm: VoiceToggleViewModel
    private let compact: Bool

    /// - Parameters:
    ///   - viewModel: inject with AppDI(SpeechCueEngine)
    ///   - compact: when true, renders icon-only pill (for tight HUDs).
    public init(viewModel: VoiceToggleViewModel, compact: Bool = false) {
        self.vm = viewModel
        self.compact = compact
    }

    public var body: some View {
        Group {
            if compact {
                Button(action: vm.toggle) {
                    Image(systemName: vm.isOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .imageScale(.large)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
                .tint(vm.isOn ? .accentColor : .gray.opacity(0.35))
                .accessibilityLabel(Text(NSLocalizedString("Voice guidance", comment: "AX label")))
                .accessibilityValue(Text(vm.isOn ? NSLocalizedString("On", comment: "on") : NSLocalizedString("Off", comment: "off")))
                .accessibilityHint(Text(NSLocalizedString("Double tap to toggle.", comment: "hint")))
                .accessibilityIdentifier("voice_toggle_compact")
                .contextMenu { quickMenu }
            } else {
                Button(action: vm.toggle) {
                    HStack(spacing: 10) {
                        Image(systemName: vm.isOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .imageScale(.large)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString("Voice guidance", comment: "title"))
                                .font(.subheadline.weight(.semibold))
                            Text(vm.isOn ? NSLocalizedString("On", comment: "on") : NSLocalizedString("Off", comment: "off"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(minWidth: 160, minHeight: 44, alignment: .center)
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(vm.isOn ? .accentColor : .gray.opacity(0.35))
                .accessibilityIdentifier("voice_toggle_full")
                .contextMenu { quickMenu }
            }
        }
    }

    // Optional quick actions (no heavy UI; safe while riding)
    @ViewBuilder
    private var quickMenu: some View {
        Button {
            vm.toggle()
        } label: {
            Label(vm.isOn ? NSLocalizedString("Mute", comment: "mute") : NSLocalizedString("Unmute", comment: "unmute"),
                  systemImage: vm.isOn ? "speaker.slash" : "speaker.wave.2")
        }
        // Future hooks: volume shortcut, language display (read-only)
    }
}

// MARK: - Convenience builders

public extension VoiceToggle {
    static func make(engine: SpeechCueControlling, compact: Bool = false) -> VoiceToggle {
        VoiceToggle(viewModel: .init(engine: engine), compact: compact)
    }
}

// MARK: - DEBUG preview

#if DEBUG
private final class EngineFake: SpeechCueControlling {
    let subj = CurrentValueSubject<Bool, Never>(true)
    var isEnabledPublisher: AnyPublisher<Bool, Never> { subj.eraseToAnyPublisher() }
    var currentLocaleIdentifier: String = Locale.current.identifier
    func setEnabled(_ on: Bool) { subj.send(on) }
    func speakPreviewSampleIfEnabled() { /* no-op */ }
}
struct VoiceToggle_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            VoiceToggle.make(engine: EngineFake(), compact: true)
            VoiceToggle.make(engine: EngineFake())
        }
        .padding()
        .preferredColorScheme(.dark)
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
    }
}
#endif

// MARK: - Integration notes
// • Wire `SpeechCueControlling` to Services/Voice/SpeechCueEngine.swift:
//   - Provide `isEnabledPublisher` (CurrentValueSubject<Bool, Never>) and `setEnabled(_:)`.
//   - Engine should persist state (e.g., UserDefaults) and immediately honor changes (pause/cancel utterances when off).
// • Place this control on Map HUD (top-right) and in Settings → Navigation to reflect the same state.
// • UITests: tap toggles icon and accessibility value; ensure no presentation during active navigation if PaywallRules blocks nothing here.
// • Safety: keep button larger than 44×44 and ensure high contrast; do not present modals while riding.


