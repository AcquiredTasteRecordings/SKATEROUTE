 // Features/Map/MapScreen.swift
 import SwiftUI
 import MapKit
 import CoreLocation
 import Combine
 
 public struct MapScreen: View {
     // Inputs
     public let source: CLLocationCoordinate2D
     public let destination: CLLocationCoordinate2D
     public let mode: RideMode
     public let onClose: () -> Void
 
     // Services
     private let locationService = AppDI.shared.locationManager
     private let matcher = AppDI.shared.matcher
     private let smoothness = AppDI.shared.motionService
     private let turnCues = TurnCueEngine()
     private let rerouteController: RerouteController
 
     // State
     @StateObject private var plannerViewModel: RoutePlannerViewMode
     @StateObject private var recorder = AppDI.shared.rideRecorder
     @State private var isRiding = false
     @State private var speedKmh: Double = 0
 
     public init(source: CLLocationCoordinate2D,
                 destination: CLLocationCoordinate2D,
                 mode: RideMode,
                 onClose: @escaping () -> Void) {
         self.source = source
         self.destination = destination
         self.mode = mode
         self.onClose = onClose
         self._plannerViewModel = StateObject(wrappedValue: RoutePlannerViewModel(routeService: AppDI.shared.routeService,
                                                                                  reducer: AppDI.shared.routeOptionsReducer,
                                                                                  offlineTiles: AppDI.shared.offlineTileManager,
                                                                                  offlineStore: AppDI.shared.offlineRouteStore))
         self.rerouteController = RerouteController(locationService: AppDI.shared.locationManager)
     }
 
     public var body: some View {
         ZStack(alignment: .top) {
             RideTelemetryHUD(recorder: recorder)
                 .padding(.top, 16)
                 .padding(.leading, 16)
                 .frame(maxWidth: .infinity, alignment: .topLeading)
 
             MapViewContainer(route: plannerViewModel.selectedRoute,
                              routeScore: plannerViewModel.selectedOption?.score ?? 0,
                              overlays: plannerViewModel.overlays)
 
             header
 
             VStack {
                 Spacer()
                 RoutePlannerView(viewModel: plannerViewModel,
                                  isRiding: $isRiding,
                                  onRideAction: toggleRide)
                 .padding(.horizontal, 12)
                 .padding(.bottom, 24)
             }
         }
         .ignoresSafeArea()
         .task {
             plannerViewModel.planRoutes(source: source, destination: destination, mode: mode)
         }
         .onAppear {
             if let cached = plannerViewModel.selectedRoute {
                 prepareTurnCues(route: cached)
                 startMonitoring(route: cached)
             }
         }
         .onDisappear {
             rerouteController.stopMonitoring()
         }
         .onReceive(locationService.$currentLocation.compactMap { $0 }) { loc in
             speedKmh = max(0, loc.speed) * 3.6
             if let route = plannerViewModel.selectedRoute {
                 attributeLiveSample(location: loc, route: route)
                 turnCues.tick(current: loc)
             }
         }
         .onChange(of: plannerViewModel.selectedOptionID) { _ in
             if let route = plannerViewModel.selectedRoute {
                 prepareTurnCues(route: route)
                 startMonitoring(route: route)
                 if isRiding {
                     recorder.start(route: route)
                 }
             }
         }
     }
 }
 
    var header: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.primary)
                    .shadow(radius: 2)
             }

            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(plannerViewModel.etaString)
                    .font(.headline)
                Text(String(format: "%.0f km/h", speedKmh))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let label = plannerViewModel.scoreLabel {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                 }
             }
         }
        .padding(.horizontal, 16)
        .padding(.top, 12)
     }
 
    func toggleRide() {
        if isRiding {
            stopRide()
        } else {
            startRide()
        }
     }
 
     func startRide() {
         locationService.requestTemporaryFullAccuracyIfNeeded(purposeKey: "NavigationPrecision")
         locationService.startUpdating()
         locationService.applyPowerBudgetForActiveNavigation()
         smoothness.start()
         recorder.start(route: plannerViewModel.selectedRoute)
         if let route = plannerViewModel.selectedRoute {
             prepareTurnCues(route: route)
         }
         isRiding = true
     }
 
     func stopRide() {
         locationService.stopUpdating()
         locationService.applyPowerBudgetForMonitoring()
         smoothness.stop()
         recorder.stop()
         isRiding = false
     }
 
    func prepareTurnCues(route: MKRoute) {
        turnCues.prepare(route: route)
    }
 
    func startMonitoring(route: MKRoute) {
        rerouteController.startMonitoring(route: route) { coordinate in
            plannerViewModel.reroute(from: coordinate)
            rerouteController.markRouteStabilized()
         }
     }
 
    func attributeLiveSample(location: CLLocation, route: MKRoute) {
        let sample = MatchSample(location: location, roughnessRMS: smoothness.currentRMS ?? 0.0)
        if let index = matcher.nearestStepIndex(on: route, to: sample) {
            let stepId = SegmentStore.shared.makeStepId(route: route, stepIndex: index)
            SegmentStore.shared.update(stepId: stepId, with: sample.roughnessRMS)
        }
     }
 }
