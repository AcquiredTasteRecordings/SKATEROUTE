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

    func applyAccuracy(_ profile: AccuracyProfile)
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

// MARK: - Legacy Facade for Call Sites
/// Lightweight facade so existing code can use `AppDI.shared`.
@MainActor
public enum AppDI {
    /// Singleton container used across the app.
    public static let shared: LiveAppDI = LiveAppDI()
}

public protocol RouteMatching: AnyObject {
    func nearestStepIndex(on route: MKRoute, to sample: MatchSample) -> Int?
    func nearestMatch(on route: MKRoute, to sample: MatchSample) -> MatchResult?
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

// NOTE: This protocol exists for legacy step-level roughness calls used by UI/HUD.
// The concrete implementation below adapts to the new actor-based SegmentStore.
public protocol SegmentStoring: AnyObject {
    func makeStepId(route: MKRoute, stepIndex: Int) -> Int
    func writeSegment(at stepIndex: Int, quality: Double, roughness: Double)
    func update(stepId: String, with roughnessRMS: Double)
    func clear()
    func readSegment(at stepIndex: Int) -> (quality: Double, roughness: Double, lastUpdated: Date, freshnessScore: Double)?
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
    func context(for route: MKRoute, gradeSummary: GradeSummary) async -> [StepContext]
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
                           mode: RideMode,
                           preferSkateLegal: Bool) async throws -> MKRoute
    func routeOptions(from source: CLLocationCoordinate2D,
                      to destination: CLLocationCoordinate2D,
                      mode: RideMode,
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

    // Closure to clear segments without depending on an ambiguous concrete type.
    private let clearSegments: () async -> Void

    public init() {
        let locationManager = LocationManagerService()
        let matcher = Matcher()

        let segmentsStore = SegmentStore.shared

        self.clearSegments = { segmentsStore.clear() }

        let elevationService = ElevationService()
        let attributionProvider = LocalAttributionProvider()
        let routeContextBuilder = RouteContextBuilder(attributes: attributionProvider,
                                                      segments: segmentsStore)
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
                                        segments: segmentsStore,
                                        motion: motionService,
                                        logger: sessionLogger)

        // Public properties
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

        // Legacy step-level roughness store (adapter over the actor for UI/HUD calls).
        self.segmentStore = segmentsStore
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
        Task { await self.clearSegments() }
        rideRecorder.stop()
    }
}

// MARK: - Protocol Conformances

extension LocationManagerService: LocationManaging {
    public var currentLocationPublisher: AnyPublisher<CLLocation?, Never> {
        $currentLocation.eraseToAnyPublisher()
    }
}

extension MotionRoughnessService: MotionRoughnessMonitoring {}

extension SessionLogger: SessionLogging {}

// Removed SkateRouteScorer extension conforming to SkateRouteScoring with per-step helpers

extension OfflineTileManager: @MainActor OfflineTileManaging {
    public func ensureTiles(for polyline: MKPolyline, identifier: String) async { }
    
    public var statePublisher: AnyPublisher<OfflineTileManager.DownloadState, Never> {
        $state.eraseToAnyPublisher()
    }

    public func currentState() -> OfflineTileManager.DownloadState {
        state
    }
}

extension OfflineRouteStore: @preconcurrency OfflineRouteStoring {
    public func store(_ snapshots: [Snapshot], for key: RequestKey) { }
}

extension RerouteController: RerouteControlling {}

// MARK: - Legacy Step-Level Roughness Adapter on SegmentStore
// We bridge the older SegmentStoring API onto the new actor so existing
// call sites keep working while the rest of the stack modernizes.

private struct _StepRecord: Codable {
    var quality: Double
    var roughness: Double
    var updatedAt: Date
}

private enum _StepRecordStore {
    nonisolated(unsafe) static var url: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("StepRoughness", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("records.json")
    }()

    static func load() -> [Int: _StepRecord] {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([Int: _StepRecord].self, from: data) else { return [:] }
        return map
    }

    static func save(_ map: [Int: _StepRecord]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try FileManager.default.moveItem(at: tmp, to: url)
        } catch { /* fail-safe: ignore */ }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

// Legacy file-backed step roughness store adapter (non-actor), avoids crossing actor isolation.
public final class StepRoughnessStore: SegmentStoring {
    public init() {}

    public func makeStepId(route: MKRoute, stepIndex: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(route.polyline.pointCount)
        hasher.combine(Int(route.expectedTravelTime.rounded()))
        hasher.combine(stepIndex)
        return hasher.finalize()
    }

    public func writeSegment(at stepIndex: Int, quality: Double, roughness: Double) {
        var map = _StepRecordStore.load()
        map[stepIndex] = _StepRecord(quality: quality, roughness: roughness, updatedAt: Date())
        _StepRecordStore.save(map)
    }

    public func update(stepId: String, with roughnessRMS: Double) {
        guard let idx = Int(stepId) else { return }
        var map = _StepRecordStore.load()
        if var rec = map[idx] {
            rec.roughness = roughnessRMS
            rec.updatedAt = Date()
            map[idx] = rec
            _StepRecordStore.save(map)
        }
    }

    public func clear() {
        _StepRecordStore.clear()
    }

    public func readSegment(at stepIndex: Int) -> (quality: Double, roughness: Double, lastUpdated: Date, freshnessScore: Double)? {
        let map = _StepRecordStore.load()
        guard let rec = map[stepIndex] else { return nil }
        let age = Date().timeIntervalSince(rec.updatedAt)
        let freshness = max(0, 1.0 - min(1.0, age / (30 * 24 * 3600)))
        return (rec.quality, rec.roughness, rec.updatedAt, freshness)
    }
}


