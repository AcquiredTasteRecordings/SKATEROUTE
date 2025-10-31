// Services/MotionRoughnessService.swift
import Foundation
import CoreMotion
import Combine

/// Service to measure surface vibration RMS for skate smoothness detection.
/// It processes device motion user acceleration data to compute a smoothed RMS value,
/// representing the roughness or smoothness of the surface beneath the device.
/// Supports dynamic sensitivity modes, adaptive noise filtering, debug logging,
/// and energy conservation by pausing updates during low activity.
public final class MotionRoughnessService {
    public static let shared = MotionRoughnessService()

    private let motion = CMMotionManager()
    private let queue = OperationQueue()
    private var cancellables = Set<AnyCancellable>()

    /// Public stream of RMS values (unitless, ~0.0–3.0+)
    public let rmsSubject = CurrentValueSubject<Double?, Never>(nil)

    /// Published property for SwiftUI bindings reflecting the latest RMS value.
    @Published public private(set) var currentRMS: Double? = nil

    /// Debug logging mode. When enabled, prints timestamped RMS values for calibration.
    public var debugLoggingEnabled: Bool = false

    /// Sensitivity modes adjusting sample rate and smoothing constants.
    public enum SensitivityMode {
        case chill      // Lower sample rate, higher smoothing for relaxed detection
        case standard   // Balanced sample rate and smoothing
        case precision  // Higher sample rate, lower smoothing for precise detection
    }

    /// Current sensitivity mode. Setting it adjusts parameters accordingly.
    public var sensitivityMode: SensitivityMode = .standard {
        didSet {
            switch sensitivityMode {
            case .chill:
                sampleHz = 50
                smoothing = 0.5
                bucketSeconds = 1.0
            case .standard:
                sampleHz = 100
                smoothing = 0.35
                bucketSeconds = 0.8
            case .precision:
                sampleHz = 200
                smoothing = 0.2
                bucketSeconds = 0.5
            }
            // Update device motion interval if running
            if motion.isDeviceMotionActive {
                motion.deviceMotionUpdateInterval = 1.0 / sampleHz
            }
        }
    }

    // Tunables - these will be adjusted dynamically based on sensitivityMode
    private var sampleHz: Double = 100            // device motion rate
    private var bucketSeconds: Double = 0.8       // window length for RMS
    private var smoothing: Double = 0.35          // EMA alpha

    private var bucket: [Double] = []
    private var ema: Double?

    /// Rolling mean and standard deviation for adaptive noise filtering
    private var rollingMean: Double = 0.0
    private var rollingVariance: Double = 0.0
    private var rollingCount: Int = 0

    /// Threshold in standard deviations to discard spikes
    private let spikeThresholdSigma: Double = 3.0

    /// Energy conservation: pause updates after no significant change for this duration (seconds)
    private let inactivityTimeout: TimeInterval = 10.0

    /// Last RMS value used to detect significant changes
    private var lastRMS: Double?

    /// Timestamp of last significant RMS change
    private var lastSignificantChangeTime: Date?

    /// Flag indicating if motion updates are currently paused for energy conservation
    private var isPausedForEnergyConservation = false

    public var isRunning: Bool { motion.isDeviceMotionActive && !isPausedForEnergyConservation }

    private init() {
        queue.qualityOfService = .userInitiated
        // Initialize parameters for default sensitivityMode
        sensitivityMode = .standard
    }

    /// Starts motion updates and RMS calculation.
    /// If already running, this has no effect.
    public func start() {
        guard CMMotionManager().isDeviceMotionAvailable else { return }
        if motion.isDeviceMotionActive { return }

        resetState()
        motion.deviceMotionUpdateInterval = 1.0 / sampleHz
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] dm, _ in
            guard let self = self, let dm = dm else { return }
            // Use userAcceleration to avoid gravity bias
            let a = dm.userAcceleration
            let mag = sqrt(a.x*a.x + a.y*a.y + a.z*a.z) // g’s

            // Adaptive noise filtering: update rolling stats and discard spikes
            self.updateRollingStats(with: mag)
            if self.isSpike(magnitude: mag) {
                // Discard this spike sample
                return
            }

            self.bucket.append(mag)

            // Emit every bucketSeconds
            let targetCount = Int(self.sampleHz * self.bucketSeconds)
            if self.bucket.count >= targetCount {
                let sumsq = self.bucket.reduce(0) { $0 + $1*$1 }
                let rms  = sqrt(sumsq / Double(self.bucket.count))
                self.bucket.removeAll(keepingCapacity: true)

                // Exponential moving average for stability
                if let ema = self.ema {
                    self.ema = ema * (1 - self.smoothing) + rms * self.smoothing
                } else {
                    self.ema = rms
                }

                // Publish updated RMS
                DispatchQueue.main.async {
                    self.rmsSubject.send(self.ema)
                    self.currentRMS = self.ema
                }

                // Debug logging
                if self.debugLoggingEnabled {
                    let timestamp = Date()
                    print("[MotionRoughnessService] \(timestamp): RMS = \(String(format: "%.4f", self.ema ?? 0))")
                }

                self.handleEnergyConservation(with: self.ema ?? 0)
            }
        }
    }

    /// Stops motion updates and resets internal state.
    public func stop() {
        guard motion.isDeviceMotionActive else { return }
        motion.stopDeviceMotionUpdates()
        resetState()
        DispatchQueue.main.async {
            self.rmsSubject.send(nil)
            self.currentRMS = nil
        }
    }

    // MARK: - Private Helpers

    /// Resets internal buffers and state variables.
    private func resetState() {
        bucket.removeAll(keepingCapacity: false)
        ema = nil
        rollingMean = 0.0
        rollingVariance = 0.0
        rollingCount = 0
        lastRMS = nil
        lastSignificantChangeTime = Date()
        isPausedForEnergyConservation = false
    }

    /// Updates rolling mean and variance using Welford's algorithm for adaptive noise filtering.
    private func updateRollingStats(with value: Double) {
        rollingCount += 1
        let delta = value - rollingMean
        rollingMean += delta / Double(rollingCount)
        let delta2 = value - rollingMean
        rollingVariance += delta * delta2
    }

    /// Returns true if the given magnitude is a spike beyond the configured sigma threshold.
    private func isSpike(magnitude: Double) -> Bool {
        guard rollingCount > 1 else { return false }
        let variance = rollingVariance / Double(rollingCount - 1)
        let stddev = sqrt(variance)
        if stddev == 0 { return false }
        let deviation = abs(magnitude - rollingMean)
        return deviation > spikeThresholdSigma * stddev
    }

    /// Handles energy conservation by pausing and resuming motion updates based on RMS changes.
    private func handleEnergyConservation(with rms: Double) {
        let now = Date()
        if let last = lastRMS {
            let diff = abs(rms - last)
            if diff >= 0.02 {
                // Significant change detected, update timestamp and resume if paused
                lastSignificantChangeTime = now
                if isPausedForEnergyConservation {
                    resumeMotionUpdates()
                }
            } else {
                // No significant change, check if timeout exceeded
                if let lastChange = lastSignificantChangeTime,
                   now.timeIntervalSince(lastChange) >= inactivityTimeout,
                   !isPausedForEnergyConservation {
                    pauseMotionUpdates()
                }
            }
        } else {
            lastSignificantChangeTime = now
        }
        lastRMS = rms
    }

    /// Pauses motion updates to save energy.
    private func pauseMotionUpdates() {
        motion.stopDeviceMotionUpdates()
        isPausedForEnergyConservation = true
        if debugLoggingEnabled {
            let timestamp = Date()
            print("[MotionRoughnessService] \(timestamp): Paused motion updates for energy conservation")
        }
    }

    /// Resumes motion updates after a pause.
    private func resumeMotionUpdates() {
        guard !motion.isDeviceMotionActive else {
            isPausedForEnergyConservation = false
            return
        }
        motion.deviceMotionUpdateInterval = 1.0 / sampleHz
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] dm, _ in
            guard let self = self, let dm = dm else { return }
            let a = dm.userAcceleration
            let mag = sqrt(a.x*a.x + a.y*a.y + a.z*a.z)

            self.updateRollingStats(with: mag)
            if self.isSpike(magnitude: mag) {
                return
            }

            self.bucket.append(mag)

            let targetCount = Int(self.sampleHz * self.bucketSeconds)
            if self.bucket.count >= targetCount {
                let sumsq = self.bucket.reduce(0) { $0 + $1*$1 }
                let rms  = sqrt(sumsq / Double(self.bucket.count))
                self.bucket.removeAll(keepingCapacity: true)

                if let ema = self.ema {
                    self.ema = ema * (1 - self.smoothing) + rms * self.smoothing
                } else {
                    self.ema = rms
                }

                DispatchQueue.main.async {
                    self.rmsSubject.send(self.ema)
                    self.currentRMS = self.ema
                }

                if self.debugLoggingEnabled {
                    let timestamp = Date()
                    print("[MotionRoughnessService] \(timestamp): RMS = \(String(format: "%.4f", self.ema ?? 0))")
                }

                self.handleEnergyConservation(with: self.ema ?? 0)
            }
        }
        isPausedForEnergyConservation = false
        if debugLoggingEnabled {
            let timestamp = Date()
            print("[MotionRoughnessService] \(timestamp): Resumed motion updates after energy conservation pause")
        }
    }
}
