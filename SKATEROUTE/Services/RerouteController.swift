// Services/RerouteController.swift
// Monitors rider drift vs. active route and triggers rerouting with guardrails.
// Power-aware, accuracy-aware, and geofence-assisted. Publishes state for UI/HUD.

import Foundation
import MapKit
import CoreLocation
import Combine
import OSLog

// MARK: - RerouteController

@MainActor
public final class RerouteController: ObservableObject {

    // MARK: Config

    public struct Config: Sendable, Equatable {
        /// Base distance (m) away from the route before we consider off-route.
        public var baseOffRouteThreshold: CLLocationDistance = 40
        /// Extra buffer (m) added when GPS accuracy is poor.
        public var accuracyHysteresis: CLLocationDistance = 15
        /// Cooldown between reroute triggers (s).
        public var rerouteCooldown: TimeInterval = 25
        /// Ignore evaluations while horizontal accuracy is worse than this (m).
        public var minUsableHorizontalAccuracy: CLLocationAccuracy = 65
        /// If speed (km/h) exceeds this, reduce threshold slightly for responsiveness.
        public var speedTightenThresholdKmh: Double = 18
        /// Tighten amount (m) when above speedTightenThresholdKmh.
        public var speedTightenMeters: CLLocationDistance = 8
        /// Maximum polyline vertex sampling for distance computation (defensive).
        public var maxVertexScan: Int = 5000
        public init() {}
    }

    // MARK: Public state

    @Published public private(set) var isMonitoring = false
    @Published public private(set) var isOffRoute = false
    @Published public private(set) var lastDistanceToRoute: CLLocationDistance = 0
    @Published public private(set) var lastEvaluationAt: Date?

    // MARK: Dependencies

    private let locationService: LocationManaging
    private let logger = Logger(subsystem: "com.yourcompany.skateroute", category: "Reroute")

    // MARK: Internals

    private var cancellables: Set<AnyCancellable> = []
    private var currentRoute: MKRoute?
    private var offRouteHandler: ((CLLocationCoordinate2D) -> Void)?
    private var lastRerouteDate: Date?
    private let cfg: Config

    // Cached map points for fast distance computation
    private var cachedPolylinePoints: [MKMapPoint] = []

    public init(locationService: LocationManaging, config: Config = .init()) {
        self.locationService = locationService
        self.cfg = config
    }

    // MARK: Lifecycle

    /// Begin monitoring drift for a specific route.
    public func startMonitoring(route: MKRoute,
                                onOffRoute: @escaping (CLLocationCoordinate2D) -> Void) {
        stopMonitoring()

        currentRoute = route
        offRouteHandler = onOffRoute
        lastRerouteDate = nil
        isOffRoute = false
        lastDistanceToRoute = 0
        lastEvaluationAt = nil
        isMonitoring = true

        cachePolylinePoints(route.polyline)

        // Lower power until we “lock” → then bump for active nav while rerouting.
        locationService.applyPowerBudgetForMonitoring()
        locationService.installGeofences(along: route)

        // Geofence edge events are cheap off-route hints.
        locationService.geofenceEventHandler = { [weak self] event in
            guard let self else { return }
            switch event {
            case .entered:
                // Entering the corridor → likely back on route.
                self.setOffRoute(false)
            case .exited(let region):
                self.logger.debug("Exited geofence \(region.identifier, privacy: .public)")
                if let location = self.locationService.currentLocation {
                    self.evaluateOffRoute(location)
                }
            }
        }

        // Continually evaluate as GPS updates stream in.
        locationService.currentLocationPublisher
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] location in
                self?.evaluateOffRoute(location)
            }
            .store(in: &cancellables)
    }

    /// Stop monitoring and clear geofences.
    public func stopMonitoring() {
        guard isMonitoring else { return }
        cancellables.removeAll()
        locationService.geofenceEventHandler = nil
        locationService.clearGeofences()
        currentRoute = nil
        offRouteHandler = nil
        lastRerouteDate = nil
        cachedPolylinePoints.removeAll(keepingCapacity: false)
        isOffRoute = false
        isMonitoring = false
        locationService.applyAccuracy(.balanced)
    }

    /// When a new route is accepted by the planner, swap monitoring target.
    public func updateRoute(_ route: MKRoute) {
        currentRoute = route
        cachePolylinePoints(route.polyline)
        locationService.installGeofences(along: route)
        // We don’t immediately clear off-route state; it will self-correct on next evaluation.
    }

    /// Hint that guidance has stabilized (e.g., just finished a reroute).
    public func markRouteStabilized() {
        locationService.applyPowerBudgetForMonitoring()
    }

    // MARK: Core evaluation

    private func evaluateOffRoute(_ location: CLLocation) {
        guard let route = currentRoute else { return }
        lastEvaluationAt = Date()

        // Ignore terrible fixes to avoid thrash.
        let hAcc = location.horizontalAccuracy
        guard hAcc > 0, hAcc <= cfg.minUsableHorizontalAccuracy else {
            logger.debug("Skipping evaluation due to poor accuracy: \(hAcc, privacy: .public)m")
            return
        }

        // Compute distance to polyline (map-point space; cheap + robust).
        let distance = distanceToRoute(location, routePolylinePoints: cachedPolylinePoints)
        lastDistanceToRoute = distance

        // Dynamic thresholding
        var threshold = cfg.baseOffRouteThreshold
        threshold += min(cfg.accuracyHysteresis, max(0, hAcc * 0.25)) // small cushion for noisy fixes
        if location.speed * 3.6 >= cfg.speedTightenThresholdKmh {
            threshold = max(10, threshold - cfg.speedTightenMeters)
        }

        if distance > threshold {
            // Check cooldown
            guard shouldTriggerReroute(now: Date()) else {
                setOffRoute(true)
                return
            }
            lastRerouteDate = Date()
            setOffRoute(true)
            locationService.applyPowerBudgetForActiveNavigation()
            logger.info("Off-route detected at \(Int(distance))m (> \(Int(threshold))m); requesting reroute.")
            offRouteHandler?(location.coordinate)
        } else {
            setOffRoute(false)
        }
    }

    private func shouldTriggerReroute(now: Date) -> Bool {
        guard let last = lastRerouteDate else { return true }
        return now.timeIntervalSince(last) > cfg.rerouteCooldown
    }

    private func setOffRoute(_ value: Bool) {
        if isOffRoute != value {
            isOffRoute = value
        }
    }

    // MARK: Distance engine

    /// Pre-extract MKMapPoints for quick segment-distance calculations.
    private func cachePolylinePoints(_ polyline: MKPolyline) {
        let n = polyline.pointCount
        guard n > 1 else {
            cachedPolylinePoints = []
            return
        }
        var pts = [MKMapPoint](repeating: .init(), count: n)
        polyline.getPoints(pts)
        if n > cfg.maxVertexScan {
            // Uniformly subsample to keep evaluation cheap on monster polylines.
            let step = Double(n - 1) / Double(cfg.maxVertexScan - 1)
            var reduced: [MKMapPoint] = []
            reduced.reserveCapacity(cfg.maxVertexScan)
            var i = 0.0
            while Int(i.rounded()) < n && reduced.count < cfg.maxVertexScan {
                reduced.append(pts[Int(i.rounded())])
                i += step
            }
            if reduced.last != pts.last { reduced.append(pts.last!) }
            cachedPolylinePoints = reduced
        } else {
            cachedPolylinePoints = pts
        }
    }

    /// Fast 2D distance from a CLLocation to a polyline by scanning segments in mercator space.
    private func distanceToRoute(_ location: CLLocation, routePolylinePoints: [MKMapPoint]) -> CLLocationDistance {
        guard routePolylinePoints.count > 1 else { return .greatestFiniteMagnitude }
        let p = MKMapPoint(location.coordinate)
        var best = CLLocationDistance.greatestFiniteMagnitude

        for i in 0..<(routePolylinePoints.count - 1) {
            let a = routePolylinePoints[i]
            let b = routePolylinePoints[i + 1]
            let d = distancePointToSegment(p, a, b)
            if d < best { best = d }
        }
        return best
    }

    /// Distance from point P to segment AB in map points (meters).
    private func distancePointToSegment(_ p: MKMapPoint, _ a: MKMapPoint, _ b: MKMapPoint) -> CLLocationDistance {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len2 = dx*dx + dy*dy
        if len2 == 0 { return p.distance(to: a) } // A==B
        // Project p onto the segment, clamp t to [0,1]
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = max(0, min(1, t))
        let proj = MKMapPoint(x: a.x + t * dx, y: a.y + t * dy)
        return p.distance(to: proj)
    }
}

// MARK: - MKPolyline convenience (points extraction)

private extension MKPolyline {
    func getPoints(_ buffer: inout [MKMapPoint]) {
        buffer.withUnsafeMutableBufferPointer { ptr in
            let range = NSRange(location: 0, length: pointCount)
            getPoints(ptr.baseAddress!, range: range)
        }
    }
}
