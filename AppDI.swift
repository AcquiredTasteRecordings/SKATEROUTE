// Core/AppDI.swift
import Foundation
import MapKit
import CoreLocation


@MainActor
final class AppDI: ObservableObject {
    static let shared = AppDI()

    // Core platform
    lazy var locationManager: LocationManagerService = LocationManagerService()
    lazy var matcher: Matcher = Matcher()
    let segmentStore: SegmentStore = .shared
    lazy var elevationService: ElevationService = ElevationService()

    // Builders / logic
    lazy var routeContextBuilder: RouteContextBuilder = RouteContextBuilder(attributes: LocalAttributionProvider())
    lazy var routeScorer: SkateRouteScorer = SkateRouteScorer()
    lazy var routeService: RouteService = RouteService(elevation: self.elevationService,
                                                         contextBuilder: self.routeContextBuilder)
      lazy var routeOptionsReducer: RouteOptionsReducer = RouteOptionsReducer(scorer: self.routeScorer)

      // Offline caching
      lazy var offlineTileManager: OfflineTileManager = OfflineTileManager()
      lazy var offlineRouteStore: OfflineRouteStore = OfflineRouteStore()
      lazy var rerouteController: RerouteController = RerouteController(locationService: self.locationManager)

    // Telemetry
    let motionService: MotionRoughnessService = .shared
    lazy var rideRecorder: RideRecorder = RideRecorder(
        location: self.locationManager,
        matcher: self.matcher,
        segments: self.segmentStore,
        motion: self.motionService,
        logger: .shared
    )

    private init() {
        // No longer initializing properties here due to lazy loading
    }

    func reset() {
        segmentStore.clear()
        rideRecorder.stop()
    }
}
