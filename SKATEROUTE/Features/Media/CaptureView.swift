// Features/Media/CaptureView.swift
// Record UI: minimal capture HUD with storage meter, audio level indicator, retro record button.
// - Integrates with Services/Media/CapturePipeline (AVFoundation session preview).
// - Safe defaults: muted preview, mono mic level meter, clear state (idle/armed/recording/interrupted).
// - UX: big round REC button, timer, remaining storage estimate, simple mode switch (1080p/720p).
// - A11y: Dynamic Type, ≥44pt targets, VO labels/hints; color + shape affordances (not just color).
// - Privacy: no contact/camera roll scraping. No tracking. Optional Analytics façade (generic taps only).

import SwiftUI
import Combine
import AVFoundation
import UIKit

// MARK: - DI seams (match your CapturePipeline)

public enum CaptureState: Equatable {
    case idle, ready, recording, interrupted(reason: String)
}

public protocol CaptureControlling: AnyObject {
    // Lifecycle
    func configureIfNeeded() async throws
    func startPreview(on layer: AVCaptureVideoPreviewLayer) throws
    func startRecording() async throws
    func stopRecording() async
    func toggleTorch(_ on: Bool) throws
    func switchCamera() async throws

    // Readouts
    var statePublisher: AnyPublisher<CaptureState, Never> { get }
    var durationPublisher: AnyPublisher<TimeInterval, Never> { get } // current clip duration
    var audioLevelPublisher: AnyPublisher<Float, Never> { get }      // RMS 0…1
    var storageEstimatePublisher: AnyPublisher<StorageEstimate, Never> { get }
    var qualityPublisher: AnyPublisher<CaptureQuality, Never> { get }

    // Mutations
    func setQuality(_ quality: CaptureQuality) async
}

public struct StorageEstimate: Sendable, Equatable {
    public let freeBytes: Int64          // device free
    public let estMinutesRemaining: Double

    public init(freeBytes: Int64, estMinutesRemaining: Double) {
        self.freeBytes = freeBytes
        self.estMinutesRemaining = estMinutesRemaining
    }
}

public enum CaptureQuality: String, CaseIterable, Sendable, Equatable {
    case p1080 = "1080p"
    case p720  = "720p"
}

// MARK: - ViewModel

@MainActor
public final class CaptureViewModel: ObservableObject {
    // Published UI state
    @Published public private(set) var state: CaptureState = .idle
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var audioLevel: Float = 0
    @Published public private(set) var storage: StorageEstimate = .init(freeBytes: 0, estMinutesRemaining: 0)
    @Published public private(set) var quality: CaptureQuality = .p1080

    @Published public var isTorchOn = false
    @Published public var showHUD = true
    @Published public var errorMessage: String?
    @Published public var infoMessage: String?

    private let controller: CaptureControlling
    private let analytics: AnalyticsLogging?

    private var cancellables = Set<AnyCancellable>()

    public init(controller: CaptureControlling, analytics: AnalyticsLogging? = nil) {
        self.controller = controller
        self.analytics = analytics
        bind()
    }

    private func bind() {
        controller.statePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.state = $0 }
            .store(in: &cancellables)

        controller.durationPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.duration = $0 }
            .store(in: &cancellables)

        controller.audioLevelPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.audioLevel = $0 }
            .store(in: &cancellables)

        controller.storageEstimatePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.storage = $0 }
            .store(in: &cancellables)

        controller.qualityPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.quality = $0 }
            .store(in: &cancellables)
    }

    public func onAppear() {
        Task {
            do {
                try await controller.configureIfNeeded()
            } catch {
                errorMessage = NSLocalizedString("Camera or mic permissions missing. Check Settings.", comment: "perm fail")
            }
        }
    }

    /// Bridge for the view to start preview without exposing `controller`.
    public func startPreview(on layer: AVCaptureVideoPreviewLayer) {
        do {
            try controller.startPreview(on: layer)
        } catch {
            errorMessage = NSLocalizedString("Couldn’t start camera preview.", comment: "preview fail")
        }
    }

    public func startStopTapped() {
        switch state {
        case .recording:
            Task { await controller.stopRecording() }
            analytics?.log(.init(name: "capture_stop",
                                 category: .capture,
                                 params: ["dur": .double(duration)]))
        case .ready, .idle:
            analytics?.log(.init(name: "capture_start",
                                 category: .capture,
                                 params: ["q": .string(quality.rawValue)]))
            Task {
                do { try await controller.startRecording() }
                catch { errorMessage = NSLocalizedString("Couldn’t start recording.", comment: "start fail") }
            }
        case .interrupted:
            infoMessage = NSLocalizedString("Session was interrupted. Try again.", comment: "interrupted")
        }
    }

    public func toggleTorch() {
        do {
            try controller.toggleTorch(!isTorchOn)
            isTorchOn.toggle()
        } catch {
            errorMessage = NSLocalizedString("Torch not available.", comment: "torch fail")
        }
    }

    public func switchCamera() {
        analytics?.log(.init(name: "capture_switch_cam",
                             category: .capture,
                             params: [:]))
        Task {
            do { try await controller.switchCamera() }
            catch { errorMessage = NSLocalizedString("Can’t switch camera now.", comment: "switch fail") }
        }
    }

    public func cycleQuality() {
        let all = CaptureQuality.allCases
        if let idx = all.firstIndex(of: quality) {
            let next = all[(idx + 1) % all.count]
            Task { await controller.setQuality(next) }
            analytics?.log(.init(name: "capture_quality",
                                 category: .capture,
                                 params: ["q": .string(next.rawValue)]))
        }
    }
}

// MARK: - View

public struct CaptureView: View {
    @ObservedObject private var vm: CaptureViewModel

    public init(viewModel: CaptureViewModel) {
        self.vm = viewModel
    }

    public var body: some View {
        ZStack {
            // Live Preview (owned by pipeline; we just host its layer)
            PreviewLayerHost(configure: { layer in
                vm.startPreview(on: layer)
            })
            .ignoresSafeArea()

            // HUD overlays
            VStack(spacing: 0) {
                topBar
                Spacer()
                centerHUD
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { vm.onAppear() }
        .overlay(toastOverlay)
        .statusBar(hidden: true)
        .accessibilityElement(children: .contain)
    }

    // MARK: Top bar: status + storage + quality

    private var topBar: some View {
        HStack(spacing: 12) {
            statusPill
            Spacer()
            storagePill
            Button(action: vm.cycleQuality) {
                Label(vm.quality.rawValue, systemImage: "gearshape")
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(Text(NSLocalizedString("Video quality", comment: "q a11y")))
            .accessibilityHint(Text(NSLocalizedString("Cycles between 1080p and 720p", comment: "q hint")))
        }
    }

    private var statusPill: some View {
        let text: String
        let color: Color
        switch vm.state {
        case .idle:        text = NSLocalizedString("Idle", comment: "idle");        color = .secondary
        case .ready:       text = NSLocalizedString("Ready", comment: "ready");      color = .green
        case .recording:   text = NSLocalizedString("REC", comment: "rec");          color = .red
        case .interrupted: text = NSLocalizedString("Paused", comment: "paused");    color = .orange
        }
        return Label(text, systemImage: "circle.fill")
            .labelStyle(.titleAndIcon)
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.black.opacity(0.35), in: Capsule())
            .accessibilityLabel(Text(text))
    }

    private var storagePill: some View {
        let minutes = vm.storage.estMinutesRemaining
        return HStack(spacing: 8) {
            Image(systemName: "externaldrive").imageScale(.medium)
            Text(String(format: NSLocalizedString("%.0f min", comment: "mins left"), minutes.isFinite ? minutes : 0))
                .font(.subheadline.weight(.semibold))
            MeterBar(progress: bounded(minutes / 60.0)) // assume 60 min max bar
                .frame(width: 64, height: 6)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.black.opacity(0.35), in: Capsule())
        .foregroundColor(.white)
        .accessibilityLabel(
            Text(
                String(
                    format: NSLocalizedString("Approximately %.0f minutes of recording left", comment: "storage a11y"),
                    minutes
                )
            )
        )
    }

    // MARK: Center HUD: timer + level meter

    private var centerHUD: some View {
        VStack(spacing: 8) {
            Text(formatTime(vm.duration))
                .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.black.opacity(0.35), in: Capsule())
                .foregroundColor(.white)
                .accessibilityLabel(
                    Text(
                        String(
                            format: NSLocalizedString("Elapsed %@", comment: "elapsed a11y"),
                            formatTime(vm.duration)
                        )
                    )
                )

            LevelMeter(level: vm.audioLevel)
                .frame(height: 16)
                .padding(.horizontal, 32)
                .accessibilityLabel(Text(NSLocalizedString("Microphone level", comment: "")))
        }
    }

    // MARK: Bottom bar: retro REC button + toggles

    private var bottomBar: some View {
        VStack(spacing: 16) {
            Button(action: vm.startStopTapped) {
                RetroRecButton(isRecording: vm.state == .recording)
                    .frame(width: 96, height: 96)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("capture_rec_button")
            .accessibilityLabel(
                Text(
                    vm.state == .recording
                    ? NSLocalizedString("Stop recording", comment: "stop a11y")
                    : NSLocalizedString("Start recording", comment: "start a11y")
                )
            )
            .accessibilityHint(Text(NSLocalizedString("Double tap to toggle recording.", comment: "")))

            HStack(spacing: 12) {
                Button(action: vm.switchCamera) {
                    Label(NSLocalizedString("Flip", comment: "flip"),
                          systemImage: "arrow.triangle.2.circlepath.camera")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityIdentifier("capture_flip")

                Button(action: vm.toggleTorch) {
                    Label(
                        vm.isTorchOn
                        ? NSLocalizedString("Torch On", comment: "")
                        : NSLocalizedString("Torch Off", comment: ""),
                        systemImage: vm.isTorchOn ? "bolt.fill" : "bolt.slash.fill"
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityIdentifier("capture_torch")
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: Toasts

    @ViewBuilder
    private var toastOverlay: some View {
        VStack {
            Spacer()
            if let msg = vm.errorMessage {
                toast(text: msg, system: "exclamationmark.triangle.fill", bg: .red)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear { autoDismiss { vm.errorMessage = nil } }
            } else if let info = vm.infoMessage {
                toast(text: info, system: "checkmark.seal.fill", bg: .green)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear { autoDismiss { vm.infoMessage = nil } }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .animation(.easeInOut, value: vm.errorMessage != nil || vm.infoMessage != nil)
    }

    private func toast(text: String, system: String, bg: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: system).imageScale(.large).accessibilityHidden(true)
            Text(text).font(.callout).multilineTextAlignment(.leading)
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(bg.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
        .foregroundColor(.white)
        .accessibilityLabel(Text(text))
    }
}

// MARK: - UI bits

fileprivate func bounded(_ v: Double) -> Double { min(max(v, 0.0), 1.0) }

fileprivate func formatTime(_ t: TimeInterval) -> String {
    let s = Int(t.rounded(.toNearestOrAwayFromZero))
    let h = s / 3600
    let m = (s % 3600) / 60
    let sec = s % 60
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, sec)
        : String(format: "%02d:%02d", m, sec)
}

fileprivate func autoDismiss(_ body: @escaping () -> Void) {
    Task {
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        await MainActor.run { body() }
    }
}

fileprivate struct RetroRecButton: View {
    let isRecording: Bool
    var body: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            Circle().inset(by: 10).fill(isRecording ? Color.red : Color.white)
                .overlay(Circle().inset(by: 10).strokeBorder(Color.black.opacity(0.15), lineWidth: 1))
                .shadow(radius: isRecording ? 8 : 2)
            Text("REC")
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .kerning(1.5)
                .foregroundColor(isRecording ? .white : .black.opacity(0.85))
                .offset(y: 40)
                .accessibilityHidden(true)
        }
        .frame(minWidth: 96, minHeight: 96)
        .contentShape(Circle())
    }
}

fileprivate struct MeterBar: View {
    let progress: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Color.green)
                    .frame(width: geo.size.width * progress)
            }
        }
        .clipShape(Capsule())
    }
}

fileprivate struct LevelMeter: View {
    let level: Float // 0…1
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<18, id: \.self) { i in
                let th = Double(i + 1) / 18.0
                Rectangle()
                    .fill(gradient(for: th))
                    .opacity(Double(level) >= th ? 1.0 : 0.15)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
    private func gradient(for t: Double) -> LinearGradient {
        let color: Color = t < 0.7 ? .green : (t < 0.9 ? .yellow : .red)
        return LinearGradient(colors: [color.opacity(0.9), color],
                              startPoint: .top,
                              endPoint: .bottom)
    }
}

// MARK: - Preview host for AVCaptureVideoPreviewLayer

fileprivate struct PreviewLayerHost: UIViewRepresentable {
    let configure: (AVCaptureVideoPreviewLayer) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = PreviewLayerView()
        configure(v.previewLayer)
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    private final class PreviewLayerView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// MARK: - Convenience builder

public extension CaptureView {
    static func make(controller: CaptureControlling,
                     analytics: AnalyticsLogging? = nil) -> CaptureView {
        CaptureView(viewModel: .init(controller: controller, analytics: analytics))
    }
}

// MARK: - DEBUG fakes

#if DEBUG
private final class CaptureControllerFake: CaptureControlling {
    private let stateS = CurrentValueSubject<CaptureState, Never>(.ready)
    private let durS = CurrentValueSubject<TimeInterval, Never>(0)
    private let lvlS = CurrentValueSubject<Float, Never>(0.2)
    private let stoS = CurrentValueSubject<StorageEstimate, Never>(
        .init(freeBytes: 5_000_000_000, estMinutesRemaining: 47)
    )
    private let qS = CurrentValueSubject<CaptureQuality, Never>(.p1080)
    private var timer: Timer?

    var statePublisher: AnyPublisher<CaptureState, Never> { stateS.eraseToAnyPublisher() }
    var durationPublisher: AnyPublisher<TimeInterval, Never> { durS.eraseToAnyPublisher() }
    var audioLevelPublisher: AnyPublisher<Float, Never> { lvlS.eraseToAnyPublisher() }
    var storageEstimatePublisher: AnyPublisher<StorageEstimate, Never> { stoS.eraseToAnyPublisher() }
    var qualityPublisher: AnyPublisher<CaptureQuality, Never> { qS.eraseToAnyPublisher() }

    func configureIfNeeded() async throws {}
    func startPreview(on layer: AVCaptureVideoPreviewLayer) throws {}

    func startRecording() async throws {
        stateS.send(.recording)
        timer?.invalidate()
        var t: TimeInterval = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            t += 0.1
            self.durS.send(t)
            self.lvlS.send(Float(Double.random(in: 0.1...0.95)))
        }
    }

    func stopRecording() async {
        timer?.invalidate()
        stateS.send(.ready)
        durS.send(0)
    }

    func toggleTorch(_ on: Bool) throws {}
    func switchCamera() async throws {}
    func setQuality(_ quality: CaptureQuality) async { qS.send(quality) }
}

struct CaptureView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            CaptureView.make(controller: CaptureControllerFake(), analytics: nil)
        }
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)

        NavigationView {
            CaptureView.make(controller: CaptureControllerFake(), analytics: nil)
        }
        .preferredColorScheme(.dark)
    }
}
#endif

// MARK: - Integration notes
// • Wire this to Services/Media/CapturePipeline.swift implementation that conforms to `CaptureControlling`.
//   - The pipeline should publish: state (idle/ready/recording/interrupted), duration seconds, audio RMS 0…1,
//     storage minutes estimate, and current quality. Respect session interruptions (calls should push .interrupted).
// • AppCoordinator routes to CaptureView from a tab or FAB. Ensure NSCameraUsageDescription/NSMicrophoneUsageDescription are in Info.plist.
// • Accessibility: REC button is a full circle target ≥96pt; controls ≥44pt; timer uses monospaced digits.
// • Performance: tear down AVPlayer/recording in pipeline when backgrounded; preview stays muted.
// • Safety: if free minutes < 1, pipeline should surface a user-visible warning; this view will display minutes regardless.
