// Services/RideRecorder.swift
// Live ride recorder: fuses GPS + motion into telemetry, step context, and logs.

import Foundation
import Combine
import CoreLocation
import MapKit

@MainActor
public final class RideRecorder: ObservableObject {

    // MARK: - DI

    private let location: LocationManaging
    private let matcher: RouteMatching
    private let segments: SegmentStore          // actor passed via DI; we call only adapter methods
    private let motion: MotionRoughnessMonitoring
    private let logger: SessionLogging

    // MARK: - Session State

    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var currentRoute: MKRoute?
    @Published public private(set) var stepIndex: Int?

    // Telemetry (HUD-ready)
    @Published public private(set) var speedKmh: Double = 0
    @Published public private(set) var avgSpeedKmh: Double = 0
    @Published public private(set) var distanceMeters: Double = 0
    @Published public private(set) var elapsed: TimeInterval = 0
    @Published public private(set) var coastRatio: Double = 0 // fraction of time with low vibration
    @Published public private(set) var lastLocation: CLLocation?

    // MARK: - Config

    private let lowRMSCoastThreshold: Double = 0.020  // g's; tune with field data
    private let speedEMAAlpha: Double = 0.25          // smoothing for speed readout
    private let minValidSpeedMps: Double = 0.3        // ~1 km/h cutoff to ignore jitter

    // MARK: - Internals

    private var cancellables = Set<AnyCancellable>()
    private var startTime: Date?
    private var lastSpeedEMA: Double = 0
    private var coastingSamples: Int = 0
    private var totalRmsSamples: Int = 0
    private var lastUpdateAt: Date?

    private var currentRMS: Double? // latest motion roughness
    private var sessionId: String?

    // MARK: - Init

    public init(location: LocationManaging,
                matcher: RouteMatching,
                segments: SegmentStore,
                motion: MotionRoughnessMonitoring,
                logger: SessionLogging) {
        self.location = location
        self.matcher = matcher
        self.segments = segments
        self.motion = motion
        self.logger = logger

        bindStreams()
    }

    // MARK: - Public API

    /// Begin a new ride recording. Optionally pass the route to enable step-level context.
    public func start(route: MKRoute?) {
        guard !isRecording else { return }
        currentRoute = route
        resetSessionCounters()

        // Power budgets
        location.applyPowerBudgetForActiveNavigation()

        // Start input streams
        motion.start()
        logger.startNewSession()

        sessionId = UUID().uuidString
        isRecording = true
        startTime = Date()
    }

    /// Stop the current recording and return to monitoring power budget.
    public func stop() {
        guard isRecording else { return }
        motion.stop()
        logger.stop()

        location.applyPowerBudgetForMonitoring()
        isRecording = false
        currentRoute = nil
        stepIndex = nil
    }

    /// Swap the active route on-the-fly (e.g., replan/reroute). Keeps counters intact.
    public func setRoute(_ route: MKRoute?) {
        currentRoute = route
    }

    // MARK: - Streams

    private func bindStreams() {
        // Motion → RMS + coasting ratio
        motion.roughnessPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] rms in
                guard let self else { return }
                self.currentRMS = rms
                guard self.isRecording, let r = rms else { return }
                self.totalRmsSamples &+= 1
                if r < self.lowRMSCoastThreshold { self.coastingSamples &+= 1 }
                if self.totalRmsSamples > 0 {
                    self.coastRatio = Double(self.coastingSamples) / Double(self.totalRmsSamples)
                }
                self.logger.append(location: nil, speedKPH: self.speedKmh, rms: r, stepIndex: self.stepIndex)
            }
            .store(in: &cancellables)

        // Location → distance, speed, elapsed, matching, logging
        location.currentLocationPublisher
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] loc in
                self?.handleLocation(loc)
            }
            .store(in: &cancellables)
    }

    // MARK: - Handlers

    private func handleLocation(_ location: CLLocation) {
        lastLocation = location
        guard isRecording else { return }

        // Elapsed
        if let start = startTime { elapsed = Date().timeIntervalSince(start) }

        // Distance & speed
        if let prev = lastUpdateAt, let last = lastLocation, last !== location {
            // If caller provided loc.speed, prefer it if valid; otherwise compute delta/time
            let dt = max(0.01, location.timestamp.timeIntervalSince(prev))
            var mps = location.speed > 0 ? location.speed : {
                let d = location.distance(from: last)
                return d / dt
            }()

            if !mps.isFinite || mps.isNaN { mps = 0 }

            // Smooth + clamp noise
            let ema = lastSpeedEMA == 0 ? mps : (speedEMAAlpha * mps + (1 - speedEMAAlpha) * lastSpeedEMA)
            lastSpeedEMA = ema
            let finalMps = ema < minValidSpeedMps ? 0 : ema

            speedKmh = finalMps * 3.6
            distanceMeters += max(0, finalMps * dt)
        } else {
            // First sample init
            lastSpeedEMA = max(0, location.speed)
        }
        lastUpdateAt = location.timestamp

        // Route matching (optional)
        if let route = currentRoute {
            let sample = MatchSample(location: location, roughnessRMS: currentRMS ?? 0, timestamp: location.timestamp)
            if let match = matcher.nearestMatch(on: route, to: sample) {
                stepIndex = match.stepIndex
                // Persist roughness hint against this step for future planning/paint
                if let rms = currentRMS {
                    let stepId = segments.makeStepId(route: route, stepIndex: match.stepIndex)
                    segments.update(stepId: String(stepId), with: rms)
                }
            }
        }

        // Session logging (lightweight)
        logger.append(location: location, speedKPH: speedKmh, rms: currentRMS ?? .nan, stepIndex: stepIndex)
    }

    // MARK: - Helpers

    private func resetSessionCounters() {
        speedKmh = 0
        avgSpeedKmh = 0
        distanceMeters = 0
        elapsed = 0
        coastRatio = 0
        stepIndex = nil
        lastSpeedEMA = 0
        lastUpdateAt = nil
        lastLocation = nil
        currentRMS = nil
        coastingSamples = 0
        totalRmsSamples = 0
    }
}


