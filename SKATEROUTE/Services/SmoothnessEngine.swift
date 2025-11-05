// Services/SmoothnessEngine.swift
import Foundation
import CoreMotion

/// Delegate protocol to receive updates from SmoothnessEngine.
public protocol SmoothnessEngineDelegate: AnyObject {
    /// Called when new roughness (RMS) and stability values are available.
    func smoothnessEngine(didUpdate roughness: Double, stability: Double)
}

/// Computes an on-device roughness score using accelerometer RMS.
///
/// SmoothnessEngine analyzes vibration data from the device's accelerometer to estimate surface roughness.
/// It adaptively adjusts the sampling rate based on detected vibration spikes and applies smoothing filters
/// to provide stable roughness and stability metrics. The roughness output is scaled by a configurable
/// sensitivity parameter to accommodate different board types such as cruiser, downhill, or street boards.
public final class SmoothnessEngine {
    private let motion = CMMotionManager()
    private var timer: Timer?
    private var samples: [Double] = []
    private let queue = OperationQueue()
    private var updateTimer: Timer?
    private var smoothedRMS: Double = 0
    private let smoothingFactor: Double = 0.1
    private var currentUpdateInterval: TimeInterval = 1.0 / 50.0
    private let minUpdateInterval: TimeInterval = 1.0 / 100.0
    private let maxUpdateInterval: TimeInterval = 1.0 / 20.0
    private let vibrationThreshold: Double = 0.5

    /// Sensitivity parameter scales the RMS output for different board types.
    /// Default is 1.0. Increase for more sensitive boards, decrease for less sensitive.
    public var sensitivity: Double = 1.0

    /// Delegate to receive updates on roughness and stability.
    public weak var delegate: SmoothnessEngineDelegate?

    public init() {}

    /// Start sampling accelerometer to compute vibration RMS (roughness).
    public func start() {
        guard motion.isAccelerometerAvailable else { return }
        currentUpdateInterval = 1.0 / 50.0
        motion.accelerometerUpdateInterval = currentUpdateInterval
        motion.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
            guard let self = self, let a = data?.acceleration else { return }
            let mag = sqrt(a.x*a.x + a.y*a.y + a.z*a.z)
            self.appendSample(mag)
            self.adjustSamplingRate(for: mag)
        }
        DispatchQueue.main.async {
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.decaySamples()
                self?.notifyDelegate()
            }
        }
    }

    public func stop() {
        motion.stopAccelerometerUpdates()
        timer?.invalidate()
        timer = nil
        samples.removeAll(keepingCapacity: false)
        smoothedRMS = 0
    }

    /// Returns current RMS over the last ~10 seconds of samples.
    public func currentRMS() -> Double {
        let s = samples
        guard !s.isEmpty else { return 0 }
        let meanSquares = s.reduce(0) { $0 + $1*$1 } / Double(s.count)
        return sqrt(meanSquares) * sensitivity
    }

    /// Stability score computed as inverse of RMS: 1 / (1 + RMS).
    public var stabilityScore: Double {
        return 1.0 / (1.0 + currentRMS())
    }

    private func appendSample(_ value: Double) {
        samples.append(value)
        // Cap memory (~10 seconds at 50Hz)
        let maxCount = 500
        if samples.count > maxCount { samples.removeFirst(samples.count - maxCount) }
    }

    private func decaySamples() {
        // Simple decay to reduce effect of stale bumps
        samples = samples.map { $0 * 0.98 }
    }

    private func adjustSamplingRate(for magnitude: Double) {
        // Increase sampling rate if vibration spikes above threshold, otherwise decrease
        if magnitude > vibrationThreshold {
            currentUpdateInterval = max(minUpdateInterval, currentUpdateInterval * 0.8)
        } else {
            currentUpdateInterval = min(maxUpdateInterval, currentUpdateInterval * 1.05)
        }
        if abs(motion.accelerometerUpdateInterval - currentUpdateInterval) > 0.001 {
            motion.accelerometerUpdateInterval = currentUpdateInterval
        }
    }

    private func notifyDelegate() {
        let rms = currentRMS()
        // Low-pass filter smoothing of RMS output
        smoothedRMS = smoothedRMS + smoothingFactor * (rms - smoothedRMS)
        let stability = 1.0 / (1.0 + smoothedRMS)
        delegate?.smoothnessEngine(didUpdate: smoothedRMS, stability: stability)
        #if DEBUG
        print("SmoothnessEngine - RMS: \(smoothedRMS), Stability: \(stability)")
        #endif
    }
}
