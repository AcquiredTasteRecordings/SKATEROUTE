// Core/AppDI.swift
import Combine
import CoreLocation
import Foundation
import MapKit
import UIKit

// MARK: - Service Protocols

public typealias LocationGeofenceEvent = LocationManagerService.GeofenceEvent

@MainActor
public protocol LocationManaging: ObservableObject {
    var currentLocation: CLLocation? { get }
    var authorization: CLAuthorizationStatus { get }
    var isTracking: Bool { get }
    var currentLocationPublisher: AnyPublisher<CLLocation?, Never> { get }
    var geofenceEventHandler: ((LocationGeofenceEvent) -> Void)? { get set }

    func applyAccuracy(_ profile: LocationManagerService.AccuracyProfile)
    func applyPowerBudgetForMonitoring()
    func applyPowerBudgetForActiveNavigation()
    func installGeofences(along route: MKRoute,
                          radius: CLLocationDistance,
                          spacing: CLLocationDistance)
    func clearGeofences()
    func startUpdating()
    func stopUpdating()
    func requestTemporaryFullAccuracyIfNeeded(purposeKey: String)
}

public protocol RouteMatching: AnyObject {
    func nearestStepIndex(on route: MKRoute, to sample: MatchSample) -> Int?
}

public protocol MotionRoughnessMonitoring: AnyObject {
    var currentRMS: Double? { get }
    var roughnessPublisher: AnyPublisher<Double?, Never> { get }
    func start()
    func stop()
}

public protocol SessionLogging: AnyObject {
    func startNewSession()
    func append(location: CLLocation?, speedKPH: Double, rms: Double, stepIndex: Int?)
    func stop()
}

public protocol SegmentStoring: AnyObject {
    func makeStepId(route: MKRoute, stepIndex: Int) -> Int
    func writeSegment(at stepIndex: Int, quality: Double, roughness: Double)
    func update(stepId: String, with roughnessRMS: Double)
    func clear()
}

public protocol ElevationServing: AnyObject {
    func summarizeGrades(on route: MKRoute, sampleMeters: Double) async -> GradeSummary
}

public extension ElevationServing {
    func summarizeGrades(on route: MKRoute) async -> GradeSummary {
        await summarizeGrades(on: route, sampleMeters: 75)
    }
}

public protocol RouteContextBuilding: AnyObject {
    func context(for route: MKRoute) async -> [StepContext]
}

public protocol SkateRouteScoring: AnyObject {
    func computeScore(for route: MKRoute,
                      roughnessRMS: Double,
                      slopePenalty: Double,
                      mode: RideMode) -> Double
    func gradeDescription(for score: Double) -> String
    func color(for score: Double) -> UIColor
}

public protocol RoutingService: AnyObject {
    func requestDirections(from source: CLLocationCoordinate2D,
                           to destination: CLLocationCoordinate2D,
                           preferSkateLegal: Bool) async throws -> MKRoute
    func routeOptions(from source: CLLocationCoordinate2D,
                      to destination: CLLocationCoordinate2D,
                      preferSkateLegal: Bool) async throws -> [RouteService.RouteCandidate]
    func clearCache()
}

public protocol RouteOptionsReducing: AnyObject {
    func evaluate(candidates: [RouteService.RouteCandidate],
                  mode: RideMode) -> [String: RouteOptionsReducer.Presentation]
}

public protocol OfflineTileManaging: AnyObject {
    var statePublisher: AnyPublisher<OfflineTileManager.DownloadState, Never> { get }
    func currentState() -> OfflineTileManager.DownloadState
    func ensureTiles(for polyline: MKPolyline, identifier: String) async
    func hasTiles(for identifier: String) -> Bool
    func reset()
}

public protocol OfflineRouteStoring: AnyObject {
    func store(_ snapshots: [OfflineRouteStore.Snapshot], for key: OfflineRouteStore.RequestKey)
    func load(for key: OfflineRouteStore.RequestKey) -> [OfflineRouteStore.Snapshot]?
}

@MainActor
public protocol RerouteControlling: ObservableObject {
    func startMonitoring(route: MKRoute, onOffRoute: @escaping (CLLocationCoordinate2D) -> Void)
    func stopMonitoring()
    func updateRoute(_ route: MKRoute)
    func markRouteStabilized()
}

// MARK: - App Dependency Container

@MainActor
public protocol AppDependencyContainer: AnyObject {
    var locationManager: LocationManaging { get }
    var matcher: RouteMatching { get }
    var elevationService: ElevationServing { get }
    var routeContextBuilder: RouteContextBuilding { get }
    var routeScorer: SkateRouteScoring { get }
    var routeService: RoutingService { get }
    var routeOptionsReducer: RouteOptionsReducing { get }
    var offlineTileManager: OfflineTileManaging { get }
    var offlineRouteStore: OfflineRouteStoring { get }
    var motionService: MotionRoughnessMonitoring { get }
    var rideRecorder: RideRecorder { get }
    var sessionLogger: SessionLogging { get }
    var segmentStore: SegmentStoring { get }

    func makeRoutePlannerViewModel() -> RoutePlannerViewModel
    func makeRerouteController() -> RerouteControlling
    func reset()
}

// MARK: - Live App Container

@MainActor
public final class LiveAppDI: ObservableObject, AppDependencyContainer {
    public let locationManager: LocationManaging
    public let matcher: RouteMatching
    public let elevationService: ElevationServing
    public let routeContextBuilder: RouteContextBuilding
    public let routeScorer: SkateRouteScoring
    public let routeService: RoutingService
    public let routeOptionsReducer: RouteOptionsReducing
    public let offlineTileManager: OfflineTileManaging
    public let offlineRouteStore: OfflineRouteStoring
    public let motionService: MotionRoughnessMonitoring
    public let rideRecorder: RideRecorder
    public let sessionLogger: SessionLogging
    public let segmentStore: SegmentStoring

    public init() {
        let locationManager = LocationManagerService()
        let matcher = Matcher()
        let segmentStore = SegmentStore.shared
        let elevationService = ElevationService()
        let routeContextBuilder = RouteContextBuilder(attributes: LocalAttributionProvider())
        let routeScorer = SkateRouteScorer()
        let motionService = MotionRoughnessService.shared
        let sessionLogger = SessionLogger.shared

        let routeService = RouteService(elevation: elevationService,
                                        contextBuilder: routeContextBuilder)
        let routeOptionsReducer = RouteOptionsReducer(scorer: routeScorer)
        let offlineTileManager = OfflineTileManager()
        let offlineRouteStore = OfflineRouteStore()
        let rideRecorder = RideRecorder(location: locationManager,
                                        matcher: matcher,
                                        segments: segmentStore,
                                        motion: motionService,
                                        logger: sessionLogger)

        self.locationManager = locationManager
        self.matcher = matcher
        self.elevationService = elevationService
        self.routeContextBuilder = routeContextBuilder
        self.routeScorer = routeScorer
        self.routeService = routeService
        self.routeOptionsReducer = routeOptionsReducer
        self.offlineTileManager = offlineTileManager
        self.offlineRouteStore = offlineRouteStore
        self.motionService = motionService
        self.rideRecorder = rideRecorder
        self.sessionLogger = sessionLogger
        self.segmentStore = segmentStore
    }

    public func makeRoutePlannerViewModel() -> RoutePlannerViewModel {
        RoutePlannerViewModel(routeService: routeService,
                              reducer: routeOptionsReducer,
                              offlineTiles: offlineTileManager,
                              offlineStore: offlineRouteStore)
    }

    public func makeRerouteController() -> RerouteControlling {
        RerouteController(locationService: locationManager)
    }

    public func reset() {
        segmentStore.clear()
        rideRecorder.stop()
    }
}

// MARK: - Protocol Conformances

extension LocationManagerService: LocationManaging {
    public var currentLocationPublisher: AnyPublisher<CLLocation?, Never> {
        $currentLocation.eraseToAnyPublisher()
    }
}

extension Matcher: RouteMatching {}

extension MotionRoughnessService: MotionRoughnessMonitoring {
    public var roughnessPublisher: AnyPublisher<Double?, Never> {
        rmsSubject.eraseToAnyPublisher()
    }
}

extension SessionLogger: SessionLogging {}

extension SegmentStore: SegmentStoring {}

extension ElevationService: ElevationServing {}

extension RouteContextBuilder: RouteContextBuilding {}

extension SkateRouteScorer: SkateRouteScoring {
    public func color(for score: Double) -> UIColor {
        color(forScore: score, mode: "standard")
    }
}

extension RouteService: RoutingService {}

extension RouteOptionsReducer: RouteOptionsReducing {}

extension OfflineTileManager: OfflineTileManaging {
    public var statePublisher: AnyPublisher<OfflineTileManager.DownloadState, Never> {
        $state.eraseToAnyPublisher()
    }

    public func currentState() -> OfflineTileManager.DownloadState {
        state
    }
}

extension OfflineRouteStore: OfflineRouteStoring {}

extension RerouteController: RerouteControlling {}
