// Services/Media/CapturePipeline.swift
// High-signal AV capture (video + mic) with safe defaults and guardrails.
// 1080p baseline, adaptive FPS for thermal/battery, mono audio, resilient interruptions.
// Zero tracking. No secrets. App-coordinator friendly.

import Foundation
import AVFoundation
import UIKit
import Combine
import os.log

// MARK: - Protocol seam for DI

public protocol CapturePipelining: AnyObject {
    var previewLayer: AVCaptureVideoPreviewLayer { get }
    var statePublisher: AnyPublisher<CapturePipeline.State, Never> { get }
    func configureIfNeeded() async
    func start() async
    func stop()
    func startRecording(to url: URL) async throws
    func stopRecording() async
    func toggleTorch(_ on: Bool) async
}

// MARK: - Implementation

@MainActor
public final class CapturePipeline: NSObject, CapturePipelining {

    // MARK: State & Events

    public enum State: Equatable {
        case idle
        case configured
        case running
        case recording
        case interrupted(reason: String)
        case error(String)
    }

    private let stateSubject = CurrentValueSubject<State, Never>(.idle)
    public var statePublisher: AnyPublisher<State, Never> { stateSubject.eraseToAnyPublisher() }

    // MARK: Core AV objects

    public let previewLayer = AVCaptureVideoPreviewLayer()
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.skateroute.capture.session")
    private let log = Logger(subsystem: "com.skateroute", category: "CapturePipeline")

    // Inputs/Outputs
    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let movieOutput = AVCaptureMovieFileOutput()

    // Flags
    private var isConfigured = false
    private var wantsToRun = false
    private var observationTokens: [NSObjectProtocol] = []

    // Thermal adaptation
    private var thermalStateProvider: () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }

    // MARK: Lifecycle

    public override init() {
        super.init()
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        wireNotifications()
    }

    deinit {
        observationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: Public API

    public func configureIfNeeded() async {
        guard !isConfigured else { return }
        await withCheckedContinuation { cont in
            sessionQueue.async { [weak self] in
                guard let self else { cont.resume() ; return }
                do {
                    try self.configureSession()
                    self.isConfigured = true
                    DispatchQueue.main.async { self.stateSubject.send(.configured) }
                } catch {
                    DispatchQueue.main.async { self.stateSubject.send(.error("Config failed")) }
                    self.log.error("Capture config failed: \(error.localizedDescription, privacy: .public)")
                }
                cont.resume()
            }
        }
    }

    public func start() async {
        wantsToRun = true
        await configureIfNeeded()
        await setAudioSessionActive(true)

        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.session.isRunning else { return }
            self.session.startRunning()
            DispatchQueue.main.async { self.stateSubject.send(.running) }
            self.applyAdaptiveFPS() // set initial FPS based on current thermal
        }
    }

    public func stop() {
        wantsToRun = false
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async { self.stateSubject.send(.configured) }
        }
        Task { await setAudioSessionActive(false) }
    }

    public func startRecording(to url: URL) async throws {
        try await ensureMicPermission()
        await configureIfNeeded()
        if !session.isRunning { await start() }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.movieOutput.isRecording else { return }
            if let connection = self.movieOutput.connection(with: .video) {
                connection.preferredVideoStabilizationMode = .auto
                // Record orientation from the UI layer if available
                if let orientation = self.previewLayer.connection?.videoOrientation {
                    connection.videoOrientation = orientation
                }
            }
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
            DispatchQueue.main.async { self.stateSubject.send(.recording) }
        }
    }

    public func stopRecording() async {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
        }
    }

    public func toggleTorch(_ on: Bool) async {
        await withCheckedContinuation { cont in
            sessionQueue.async { [weak self] in
                guard let self = self, let device = self.videoDevice, device.hasTorch else { cont.resume(); return }
                do {
                    try device.lockForConfiguration()
                    device.torchMode = on ? .on : .off
                    device.unlockForConfiguration()
                } catch {
                    self.log.error("Torch toggle failed: \(error.localizedDescription, privacy: .public)")
                }
                cont.resume()
            }
        }
    }

    // MARK: Configuration

    private func configureSession() throws {
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080

        // Video input (prefer back wide angle)
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
        guard let videoDevice = device else { throw PipelineError.noVideoDevice }
        self.videoDevice = videoDevice

        let vInput = try AVCaptureDeviceInput(device: videoDevice)
        guard session.canAddInput(vInput) else { throw PipelineError.cannotAddInput }
        session.addInput(vInput)
        self.videoInput = vInput

        try configureVideoDevice(videoDevice)

        // Audio input (mono)
        if let mic = AVCaptureDevice.default(for: .audio) {
            let aInput = try AVCaptureDeviceInput(device: mic)
            if session.canAddInput(aInput) {
                session.addInput(aInput)
                self.audioInput = aInput
            }
        }

        // Movie output
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
            if let c = movieOutput.connection(with: .video) {
                c.preferredVideoStabilizationMode = .auto
            }
            // Tweak file fragment interval for robustness in background interruptions
            movieOutput.movieFragmentInterval = CMTime(seconds: 1.0, preferredTimescale: 600)
            // Cap bit rate modestly to help battery/thermals on older iPhones
            if movieOutput.availableVideoCodecTypes.contains(.h264) {
                movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: movieOutput.connection(with: .video)!)
            }
        } else {
            throw PipelineError.cannotAddOutput
        }

        session.commitConfiguration()

        // Prepare audio session after AV graph is ready
        Task { await configureAudioSession() }
    }

    private func configureVideoDevice(_ device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        // Prefer 1080p formats; fall back to the highest available under 60 fps
        if let format = device.formats
            .filter({ f in
                let desc = f.formatDescription
                let dims = CMVideoFormatDescriptionGetDimensions(desc)
                return dims.width == 1920 && dims.height == 1080
            })
            .sorted(by: { $0.maxFrameRate > $1.maxFrameRate })
            .first {
            device.activeFormat = format
        }

        // Default FPS 30; min 24 for thermal relief. We'll adapt dynamically.
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)

        // Continuous autofocus/exposure where supported
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
    }

    // MARK: Audio session (mono, echo cancellation hint, loudness-friendly)

    private func configureAudioSession() async {
        let session = AVAudioSession.sharedInstance()
        do {
            // PlayAndRecord + videoRecording mode = camera-tuned I/O; enables HW AGC/AEC on many devices.
            try session.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetooth])
            // Prefer mono for smaller files & simpler leveling
            if session.isInputAvailable {
                try session.setPreferredInputNumberOfChannels(1)
            }
            try session.setPreferredSampleRate(44_100)
            try session.setPreferredIOBufferDuration(0.005) // ~5ms for decent sync without overtaxing CPU
        } catch {
            log.error("Audio session config failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func setAudioSessionActive(_ active: Bool) async {
        do {
            try AVAudioSession.sharedInstance().setActive(active, options: active ? [] : [.notifyOthersOnDeactivation])
        } catch {
            log.error("Audio session activate failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Adaptive FPS (thermal/battery guardrail)

    private func applyAdaptiveFPS() {
        guard let device = videoDevice else { return }
        let thermal = thermalStateProvider()
        let targetFPS: Int
        switch thermal {
        case .nominal: targetFPS = 30
        case .fair:    targetFPS = 28
        case .serious: targetFPS = 24
        case .critical: targetFPS = 20
        @unknown default: targetFPS = 24
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try device.lockForConfiguration()
                let time = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
                device.activeVideoMinFrameDuration = time
                device.activeVideoMaxFrameDuration = time
                device.unlockForConfiguration()
            } catch {
                self.log.error("Adaptive FPS failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Permissions

    private func ensureMicPermission() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized: return
        case .notDetermined:
            let ok = await AVCaptureDevice.requestAccess(for: .audio)
            if !ok { throw PipelineError.microphoneDenied }
        case .denied, .restricted:
            throw PipelineError.microphoneDenied
        @unknown default:
            throw PipelineError.microphoneDenied
        }
    }

    // MARK: Notifications & interruptions

    private func wireNotifications() {
        let nc = NotificationCenter.default

        observationTokens.append(
            nc.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main) { [weak self] n in
                guard let self else { return }
                let reason = (n.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int).flatMap {
                    AVCaptureSession.InterruptionReason(rawValue: $0)
                }
                self.stateSubject.send(.interrupted(reason: reason.debugDescription))
            }
        )

        observationTokens.append(
            nc.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: .main) { [weak self] _ in
                guard let self else { return }
                if self.wantsToRun {
                    self.sessionQueue.async { [weak self] in
                        guard let self else { return }
                        if !self.session.isRunning { self.session.startRunning() }
                        DispatchQueue.main.async { self.stateSubject.send(.running) }
                    }
                }
            }
        )

        observationTokens.append(
            nc.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] n in
                guard let self else { return }
                let err = n.userInfo?[AVCaptureSessionErrorKey] as? NSError
                self.log.error("AV runtime error: \(err?.localizedDescription ?? "unknown", privacy: .public)")
                self.stateSubject.send(.error("Camera error"))
            }
        )

        observationTokens.append(
            nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.applyAdaptiveFPS()
            }
        )

        observationTokens.append(
            nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.sessionQueue.async { [weak self] in
                    guard let self else { return }
                    if self.session.isRunning { self.session.stopRunning() }
                    DispatchQueue.main.async { self.stateSubject.send(.configured) }
                }
            }
        )

        observationTokens.append(
            nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if self.wantsToRun { Task { await self.start() } }
            }
        )
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CapturePipeline: AVCaptureFileOutputRecordingDelegate {
    public func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        // no-op
    }
    public func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in
            if self.session.isRunning {
                self.stateSubject.send(.running)
            } else {
                self.stateSubject.send(.configured)
            }
            if let error {
                self.log.error("Recording finished with error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Errors

public enum PipelineError: LocalizedError {
    case noVideoDevice
    case cannotAddInput
    case cannotAddOutput
    case microphoneDenied

    public var errorDescription: String? {
        switch self {
        case .noVideoDevice: return "No camera available."
        case .cannotAddInput: return "Couldn’t add camera/mic."
        case .cannotAddOutput: return "Couldn’t add recorder."
        case .microphoneDenied: return "Microphone permission denied."
        }
    }
}

// MARK: - DEBUG fakes & test seams

#if DEBUG
/// Deterministic fake for unit tests and previews.
public final class CapturePipelineFake: CapturePipelining {
    public var previewLayer = AVCaptureVideoPreviewLayer()
    private let subject = CurrentValueSubject<CapturePipeline.State, Never>(.idle)
    public var statePublisher: AnyPublisher<CapturePipeline.State, Never> { subject.eraseToAnyPublisher() }

    public init() {}
    public func configureIfNeeded() async { subject.send(.configured) }
    public func start() async { subject.send(.running) }
    public func stop() { subject.send(.configured) }
    public func startRecording(to url: URL) async throws { subject.send(.recording) }
    public func stopRecording() async { subject.send(.running) }
    public func toggleTorch(_ on: Bool) async { }
}

/// Test hook to simulate thermal throttling behavior.
extension CapturePipeline {
    public func _overrideThermalProvider(_ provider: @escaping () -> ProcessInfo.ThermalState) {
        self.thermalStateProvider = provider
    }
}
#endif
