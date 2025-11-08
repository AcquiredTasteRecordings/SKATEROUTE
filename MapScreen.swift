// Features/Map/MapScreen.swift
import Combine
import CoreLocation
import MapKit
import SwiftUI

public struct MapScreen: View {
    // Inputs
    public let source: CLLocationCoordinate2D
    public let destination: CLLocationCoordinate2D
    public let mode: RideMode

    private let onClose: () -> Void
    private let dependencies: any AppDependencyContainer
    private let locationService: LocationManaging
    private let matcher: RouteMatching
    private let motionService: MotionRoughnessMonitoring
    private let rerouteController: RerouteControlling
    private let turnCueEngine = TurnCueEngine()

    // State
    @StateObject private var plannerViewModel: RoutePlannerViewModel
    @ObservedObject private var recorder: RideRecorder
    @State private var isRiding = false
    @State private var speedKmh: Double = 0

    public init(source: CLLocationCoordinate2D,
                destination: CLLocationCoordinate2D,
                mode: RideMode,
                dependencies: any AppDependencyContainer,
                onClose: @escaping () -> Void) {
        self.source = source
        self.destination = destination
        self.mode = mode
        self.dependencies = dependencies
        self.onClose = onClose

        self.locationService = dependencies.locationManager
        self.matcher = dependencies.matcher
        self.motionService = dependencies.motionService
        self.rerouteController = dependencies.makeRerouteController()

        _plannerViewModel = StateObject(wrappedValue: dependencies.makeRoutePlannerViewModel())
        _recorder = ObservedObject(wrappedValue: dependencies.rideRecorder)
    }

    public var body: some View {
        ZStack(alignment: .top) {
            RideTelemetryHUD(recorder: recorder)
                .padding(.top, 16)
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, alignment: .topLeading)

            MapViewContainer(route: plannerViewModel.selectedRoute,
                             gradeSummary: plannerViewModel.slopeSummary,
                             stepContexts: plannerViewModel.selectedOption?.metadata.stepContexts ?? [],
                             routeScore: plannerViewModel.selectedOption?.score ?? 0,
                             overlays: plannerViewModel.overlays,
                             scorer: dependencies.routeScorer,
                             rideMode: mode)

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
                prepareTurnCues(route: cached,
                                 contexts: plannerViewModel.selectedOption?.metadata.stepContexts ?? [])
                startMonitoring(route: cached)
            }
        }
        .onDisappear {
            rerouteController.stopMonitoring()
        }
        .onReceive(locationService.currentLocationPublisher.compactMap { $0 }) { location in
            speedKmh = max(0, location.speed) * 3.6
            if let route = plannerViewModel.selectedRoute {
                attributeLiveSample(location: location, route: route)
                turnCueEngine.tick(current: location)
            }
        }
        .onChange(of: plannerViewModel.selectedOptionID) { _ in
            if let route = plannerViewModel.selectedRoute {
                prepareTurnCues(route: route,
                                 contexts: plannerViewModel.selectedOption?.metadata.stepContexts ?? [])
                startMonitoring(route: route)
                if isRiding {
                    recorder.start(route: route,
                                 contexts: plannerViewModel.selectedOption?.metadata.stepContexts ?? [])
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Button {
                if isRiding { stopRide() }
                onClose()
            } label: {
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

    private func toggleRide() {
        if isRiding {
            stopRide()
        } else {
            startRide()
        }
    }

    private func startRide() {
        locationService.requestTemporaryFullAccuracyIfNeeded(purposeKey: "NavigationPrecision")
        locationService.startUpdating()
        locationService.applyPowerBudgetForActiveNavigation()
        motionService.start()
        if let route = plannerViewModel.selectedRoute {
            recorder.start(route: route,
                                   contexts: plannerViewModel.selectedOption?.metadata.stepContexts ?? [])
            prepareTurnCues(route: route,
                                    contexts: plannerViewModel.selectedOption?.metadata.stepContexts ?? [])
        }
        isRiding = true
    }

    private func stopRide() {
        locationService.stopUpdating()
        locationService.applyPowerBudgetForMonitoring()
        motionService.stop()
        recorder.stop()
        isRiding = false
    }

    private func prepareTurnCues(route: MKRoute, contexts: [StepContext]) {
            turnCueEngine.prepare(route: route, contexts: contexts)
    }

    private func startMonitoring(route: MKRoute) {
        rerouteController.startMonitoring(route: route) { coordinate in
            plannerViewModel.reroute(from: coordinate)
            rerouteController.markRouteStabilized()
        }
    }

    private func attributeLiveSample(location: CLLocation, route: MKRoute) {
        let sample = MatchSample(location: location, roughnessRMS: motionService.currentRMS ?? 0.0)
        if let result = matcher.nearestMatch(on: route, to: sample) {
            let store = dependencies.segmentStore
            let stepId = store.makeStepId(route: route, stepIndex: result.stepIndex)
            store.update(stepId: String(stepId), with: sample.roughnessRMS)
        }
    }
}
