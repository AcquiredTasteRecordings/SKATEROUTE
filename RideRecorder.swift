// Services/RideRecorder.swift
import Foundation
import Combine
import MapKit
import CoreLocation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(SwiftUI)
import SwiftUI
#endif

private func triggerStartStopHaptic() {
#if canImport(UIKit)
    DispatchQueue.main.async {
        if #available(iOS 13.0, *) {
            let generator = UISelectionFeedbackGenerator()
            generator.prepare()
            generator.selectionChanged()
        }
    }
#endif
}

/// `RideRecorder` is responsible for tracking the user's motion and mapping real-world rides.
/// It integrates location updates, motion roughness data, and route matching to provide a comprehensive
/// recording of a ride session. This includes speed tracking, distance accumulation, segment updates,
/// and session logging. It also provides haptic feedback on start and stop events, and adapts location
/// accuracy based on the current speed.
@MainActor
public final class RideRecorder: ObservableObject {
    
    // this one is only to let AppDI construct us easily in older code paths
    public static let placeholder = RideRecorder(
        location: LocationManagerService(),
        matcher: Matcher(),
        segments: .shared,
        motion: .shared,
        logger: SessionLogger.shared
    )
    
    @Published public private(set) var speedKPH: Double = 0
    @Published public private(set) var lastRMS: Double = 0
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var distanceMeters: Double = 0
    
    private var cancellables = Set<AnyCancellable>()
    
    private let location: LocationManaging
    private let matcher: RouteMatching
    private let segments: SegmentStoring
    private let motion: MotionRoughnessMonitoring
    private let logger: SessionLogging
    
    private var activeRoute: MKRoute?
    private var lastLocation: CLLocation?
    
    public init(location: LocationManagerService,
                matcher: Matcher,
                segments: SegmentStore,
                motion: MotionRoughnessService,
                logger: SessionLogger) {
        self.location = location
        self.matcher = matcher
        self.segments = segments
        self.motion = motion
        self.logger = logger
    }
    
    public func start(route: MKRoute?) {
        guard !isRecording else { return }
        activeRoute = route
        isRecording = true
        distanceMeters = 0
        lastLocation = nil
        
        logger.startNewSession()
        
        // Haptic feedback on start
        triggerStartStopHaptic()
        
        // ---- LOCATION STREAM ----
        location.currentLocationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] maybeLoc in
                guard let self = self else { return }
                // unwrap the optional properly
                guard let loc = maybeLoc else { return }
                
                // speed
                let speed = max(0, loc.speed) * 3.6
                self.speedKPH = speed
                
                // adaptive motion accuracy
                if speed > 20,
                   let objcLocation = self.location as? NSObject,
                   objcLocation.responds(to: Selector(("setHighAccuracyMode"))) {
                    objcLocation.perform(Selector(("setHighAccuracyMode")))
                }
                
                // accumulate distance
                if let lastLoc = self.lastLocation {
                    let delta = loc.distance(from: lastLoc)
                    self.distanceMeters += delta
                }
                self.lastLocation = loc
                
                // try to match to route (if any)
                var matchedIndex: Int? = nil
                if let r = self.activeRoute {
#if canImport(MapKit)
                    let sample = MatchSample(location: loc, roughnessRMS: self.lastRMS)
                    if let idx = self.matcher.nearestStepIndex(on: r, to: sample) {
                        matchedIndex = idx
                        self.segments.writeSegment(at: idx, quality: 1.0, roughness: self.lastRMS)
                        print("Segment updated: stepIndex = \(idx), RMS = \(self.lastRMS)")
                    }
#endif
                }
                
                // log every tick
                self.logger.append(location: loc,
                                   speedKPH: speed,
                                   rms: self.lastRMS,
                                   stepIndex: matchedIndex)
            }
            .store(in: &cancellables)
        
        // ---- MOTION STREAM ----
        motion.roughnessPublisher
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rms in
                self?.lastRMS = rms
            }
            .store(in: &cancellables)
        
        motion.start()
        // if your LocationManagerService has this, keep it. otherwise delete.
        // location.applyAccuracy(.fitness)
    }
    
    public func stop() {
        guard isRecording else { return }
        isRecording = false
        
        motion.stop()
        logger.stop()
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        activeRoute = nil
        lastLocation = nil
        
        // Haptic feedback on stop
        triggerStartStopHaptic()
    }
}
