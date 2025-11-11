// Services/SmoothnessEngine.swift
// On-device surface roughness estimator (RMS) + stability metric.
// Consistent with our power budgets and HUDs. Uses CMDeviceMotion.userAcceleration when available
// (gravity-compensated), falls back to raw accelerometer. Adaptive sampling, EMA smoothing,
// Combine publisher, delegate callback, lifecycle-aware start/stop, and battery-light.

import Foundation
import CoreMotion
import Combine
import OSLog
import UIKit

// MARK: - Delegate

public protocol SmoothnessEngineDelegate: AnyObject {
    /// Called on main with smoothed roughness (RMS; higher = rougher) and stability in [0,1].
    func smoothnessEngine(didUpdate roughness: Double, stability: Double)
}

// MARK: - Sensitivity preset

/// Board sensitivity presets (multiplier applied to RMS).
public enum BoardSensitivity: Double, Sendable {
    case cruiser  = 0.85
    case downhill = 0.70
    case street   = 1.00
}

// MARK: - Engine

public final class SmoothnessEngine: ObservableObject {

    // MARK: Config

    public struct Config: Sendable, Equatable {
        /// Target EMA smoothing alpha for RMS (0…1). Higher = snappier.
        public var smoothingAlpha: Double = 0.18
        /// Base and min/max update frequencies, Hz.
        public var baseHz: Double = 50
        public var minHz: Double  = 20
        public var maxHz: Double  = 100
        /// Magnitude threshold where we tighten sampling (m/s²).
        public var spikeThreshold: Double = 0.55
        /// Approximate sample window (seconds) retained for RMS.
        public var windowSeconds: Double = 10
        /// Whether to auto-pause updates when the app is in background.
        public var pauseInBackground: Bool = true
        public init() {}
    }

    // MARK: Public outputs

    @Published public private(set) var roughnessRMS: Double = 0.0   // smoothed & sensitivity-scaled
    @Published public private(set) var stability: Double = 1.0      // 1 / (1 + roughnessRMS)
    @Published public private(set) var isRunning: Bool = false

    public weak var delegate: SmoothnessEngineDelegate?

    /// Combine stream for consumers that don’t use @Published.
    public var publisher: AnyPublisher<(roughness: Double, stability: Double), Never> {
        subject.eraseToAnyPublisher()
    }

    // MARK: Internals

    private let cfg: Config
    private let log = Logger(subsystem: "com.yourcompany.skateroute", category: "Smoothness")
    private let motion = CMMotionManager()
    private let queue = OperationQueue() // motion callbacks
    private var tickTimer: Timer?        // main-thread tick for EMA + notifications
    private var bag: Set<AnyCancellable> = []

    // Raw magnitude ring buffer (cheap doubles)
    private var samples: [Double] = []
    private var maxSampleCount: Int { Int(cfg.windowSeconds * currentHz) }
    private var currentHz: Double
    private var emaRMS: Double = 0

    // Publishers / state
    private let subject = PassthroughSubject<(Double, Double), Never>()
    private var usingDeviceMotion = false
    private var backgroundObserverTokens: [NSObjectProtocol] = []

    /// Sensitivity multiplier. Use `setSensitivity(_:)` to change at runtime.
    public private(set) var sensitivity: Double = BoardSensitivity.street.rawValue

    // MARK: Init

    public init(config: Config = .init()) {
        self.cfg = config
        self.currentHz = config.baseHz
        queue.name = "SmoothnessEngine.MotionQueue"
        queue.qualityOfService = .userInitiated
        installLifecycleObservers()
    }

    deinit { removeLifecycleObservers() }

    // MARK: Public API

    public func setSensitivity(_ preset: BoardSensitivity) {
        sensitivity = preset.rawValue
    }

    /// Start sampling (idempotent).
    public func start() {
        guard !isRunning else { return }

        // Choose best motion source
        usingDeviceMotion = motion.isDeviceMotionAvailable
        currentHz = clamp(cfg.baseHz, cfg.minHz, cfg.maxHz)
        samples.removeAll(keepingCapacity: true)
        emaRMS = 0

        if usingDeviceMotion {
            motion.deviceMotionUpdateInterval = 1.0 / currentHz
            // Use .xArbitraryZVertical for stable gravity removal at most orientations
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] data, _ in
                guard let self, let dm = data else { return }
                // gravity-compensated acceleration (m/s^2)
                let a = dm.userAcceleration
                let mag = sqrt(a.x*a.x + a.y*a.y + a.z*a.z)
                self.ingest(magnitude: mag)
            }
        } else if motion.isAccelerometerAvailable {
            motion.accelerometerUpdateInterval = 1.0 / currentHz
            motion.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
                guard let self, let a = data?.acceleration else { return }
                // Using g's (~9.81 m/s^2); relative magnitude still correlates with roughness
                let mag = sqrt(a.x*a.x + a.y*a.y + a.z*a.z)
                self.ingest(magnitude: mag)
            }
        } else {
            log.error("No motion source available; SmoothnessEngine disabled.")
            return
        }

        // Main-thread tick for EMA and delegate/publisher notifications
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tickTimer?.invalidate()
            self.tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 8.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(self.tickTimer!, forMode: .common)
        }

        isRunning = true
        log.debug("SmoothnessEngine started. DeviceMotion=\(self.usingDeviceMotion, privacy: .public). Hz=\(self.currentHz, privacy: .public)")
    }

    /// Stop sampling and release sensors.
    public func stop() {
        guard isRunning else { return }
        motion.stopDeviceMotionUpdates()
        motion.stopAccelerometerUpdates()
        tickTimer?.invalidate()
        tickTimer = nil
        samples.removeAll(keepingCapacity: false)
        emaRMS = 0
        roughnessRMS = 0
        stability = 1
        isRunning = false
        log.debug("SmoothnessEngine stopped.")
    }

    /// Lightweight one-shot snapshot of current smoothed metrics.
    public func snapshot() -> (roughness: Double, stability: Double) {
        (roughnessRMS, stability)
    }

    // MARK: Private (ingest + tick)

    /// Called on motion queue.
    private func ingest(magnitude: Double) {
        // Adaptive sampling: tighten when spikes exceed threshold; relax otherwise.
        adaptSampling(for: magnitude)

        // Feed ring buffer; keep memory bounded
        samples.append(magnitude)
        let overflow = samples.count - max(50, maxSampleCount) // keep minimum 50 samples
        if overflow > 0 { samples.removeFirst(overflow) }
    }

    /// Called on main at ~8 Hz to compute EMA and publish.
    @MainActor
    private func tick() {
        guard !samples.isEmpty else {
            // Publish clean zeros for HUDs when idle
            publish(roughness: 0, stability: 1)
            return
        }

        // Compute instantaneous RMS over current buffer
        let count = max(1, samples.count)
        let meanSquares = samples.reduce(0.0) { $0 + $1*$1 } / Double(count)
        let instantRMS = sqrt(meanSquares) * sensitivity

        // EMA smoothing
        let a = clamp(cfg.smoothingAlpha, 0, 1)
        emaRMS = emaRMS + a * (instantRMS - emaRMS)

        let smoothed = max(0, emaRMS)
        let stab = 1.0 / (1.0 + smoothed)

        publish(roughness: smoothed, stability: stab)
    }

    @MainActor
    private func publish(roughness: Double, stability: Double) {
        roughnessRMS = roughness
        self.stability = stability
        delegate?.smoothnessEngine(didUpdate: roughness, stability: stability)
        subject.send((roughness, stability))
    }

    // MARK: Sampling control

    /// Adjust Hz based on spike threshold; applied to the active motion source.
    private func adaptSampling(for magnitude: Double) {
        let spike = magnitude > cfg.spikeThreshold
        let nextHz: Double
        if spike {
            nextHz = clamp(currentHz * 1.10, cfg.baseHz, cfg.maxHz)
        } else {
            nextHz = clamp(currentHz * 0.96, cfg.minHz, cfg.baseHz)
        }
        guard abs(nextHz - currentHz) >= 0.5 else { return } // avoid thrash
        currentHz = nextHz

        if usingDeviceMotion {
            let desired = 1.0 / currentHz
            // Only change if different enough to matter.
            if abs(motion.deviceMotionUpdateInterval - desired) > 0.001 {
                motion.deviceMotionUpdateInterval = desired
            }
        } else if motion.isAccelerometerAvailable {
            let desired = 1.0 / currentHz
            if abs(motion.accelerometerUpdateInterval - desired) > 0.001 {
                motion.accelerometerUpdateInterval = desired
            }
        }
    }

    // MARK: Lifecycle

    private func installLifecycleObservers() {
        guard cfg.pauseInBackground else { return }
        let center = NotificationCenter.default

        let willEnterForeground = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.isRunning == false { return }
            // If caller left us running, resume sensors.
            self.start()
        }

        let didEnterBackground = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.isRunning { self.stop() } // pause to save battery
        }

        backgroundObserverTokens = [willEnterForeground, didEnterBackground]
    }

    private func removeLifecycleObservers() {
        for t in backgroundObserverTokens { NotificationCenter.default.removeObserver(t) }
        backgroundObserverTokens.removeAll()
    }
}

// MARK: - Utilities

private func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { max(lo, min(hi, v)) }
