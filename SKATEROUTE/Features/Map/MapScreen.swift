// Features/Map/MapScreen.swift
import SwiftUI
import MapKit
import CoreLocation
import UIKit

public struct MapScreen: View {
    // Inputs
    public let source: CLLocationCoordinate2D
    public let destination: CLLocationCoordinate2D
    public let mode: RideMode
    public let onClose: () -> Void

    // Services (updated names to match AppDI we just fixed)
    private let locationService = AppDI.shared.locationManager
    private let routeService = AppDI.shared.routeService
    private let scorer = AppDI.shared.routeScorer
    private let smoothness = AppDI.shared.smoothnessEngine
    private let elevation = ElevationService()
    private let matcher = AppDI.shared.matcher
    private let turnCues = TurnCueEngine()

    // State
    @State private var route: MKRoute?
    @State private var isRiding = false
    @State private var lastLocation: CLLocation?
    @State private var speedKmh: Double = 0
    @State private var etaString: String = "--"
    @State private var slopePenalty: Double = 0
    @State private var brakingMask: [Bool] = []
    @State private var stepContext: [StepContext] = []

    // 👇 fixed: use the DI-wide recorder
    @StateObject private var recorder = AppDI.shared.rideRecorder

    public init(source: CLLocationCoordinate2D,
                destination: CLLocationCoordinate2D,
                mode: RideMode,
                onClose: @escaping () -> Void) {
        self.source = source
        self.destination = destination
        self.mode = mode
        self.onClose = onClose
    }

    public var body: some View {
        ZStack(alignment: .top) {
            // HUD first so it's on top
            RideTelemetryHUD(recorder: AppDI.shared.rideRecorder)
                .padding(.top, 16)
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, alignment: .topLeading)

            // Map
            MapViewContainer(route: route, routeScore: 0, overlays: [])

            // Top bar
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.primary)
                        .shadow(radius: 2)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text(etaString).font(.headline)
                    Text(String(format: "%.0f km/h", speedKmh))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Bottom controls
            VStack {
                Spacer()
                HStack {
                    Button(isRiding ? "Stop" : "Start") {
                        isRiding ? stopRide() : startRide()
                    }
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(isRiding ? Color.red.opacity(0.9) : Color.green.opacity(0.9))
                    .foregroundColor(.white)
                    .clipShape(Capsule())

                    Spacer()

                    if let r = route {
                        RoutePreviewCard(route: r,
                                         slopePenalty: slopePenalty,
                                         brakingCount: brakingMask.filter { $0 }.count)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
            }
        }
        .ignoresSafeArea()
        .task {
            await loadRoute()
        }
        .onReceive(locationService.$currentLocation) { optionalLoc in
            guard let loc = optionalLoc else { return }
            lastLocation = loc
            speedKmh = max(0, loc.speed) * 3.6
            updateETA()

            if let r = route {
                // Attribute live RMS to nearest step and persist
                let sample = MatchSample(location: loc, roughnessRMS: smoothness.currentRMS())
                if let i = matcher.nearestStepIndex(on: r, to: sample) {
                    let stepId = SegmentStore.shared.makeStepId(step: r.steps[i], index: i)
                    SegmentStore.shared.update(stepId: stepId, with: sample.roughnessRMS)
                }
                // Turn cues
                turnCues.tick(current: loc)
            }

            // Recolor overlays (currently no-op)
            recomputeOverlays()
        }
    }
}

// MARK: - Async loading & helpers

private extension MapScreen {
    func loadRoute() async {
        do {
            let r = try await mkRoute(from: source, to: destination)
            await MainActor.run {
                self.route = r
            }

            // Slope summary
            let summary = await elevation.summarizeGrades(on: r)
            await MainActor.run {
                self.slopePenalty = summary.slopePenalty
                self.brakingMask = summary.brakingMask
            }

            // Step context (lanes / hazards / turn geometry)
            let ctx = await AppDI.shared.routeContextBuilder.context(for: r)
            await MainActor.run {
                self.stepContext = ctx
            }

            // Prepare turn cues
            turnCues.prepare(route: r)

            await MainActor.run {
                updateETA()
                recomputeOverlays()
            }
        } catch {
            print("[MapScreen] route error: \(error)")
        }
    }

    /// Fallback route builder that uses MapKit directly.
    func mkRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> MKRoute {
        let src = MKPlacemark(coordinate: from)
        let dst = MKPlacemark(coordinate: to)
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: src)
        req.destination = MKMapItem(placemark: dst)
        req.transportType = .walking
        req.requestsAlternateRoutes = false

        let directions = MKDirections(request: req)
        return try await withCheckedThrowingContinuation { cont in
            directions.calculate { response, error in
                if let route = response?.routes.first {
                    cont.resume(returning: route)
                } else {
                    cont.resume(throwing: error ?? NSError(domain: "MapScreen", code: -1, userInfo: [NSLocalizedDescriptionKey: "No route returned"]))
                }
            }
        }
    }

    func updateETA() {
        guard let r = route else { etaString = "--"; return }
        let minutes = max(1, Int(r.expectedTravelTime / 60))
        etaString = "\(minutes) min"
    }

    func startRide() {
        // use the DI name we now have
        AppDI.shared.locationManager.requestTemporaryFullAccuracyIfNeeded(purposeKey: "NavigationPrecision")
        AppDI.shared.locationManager.startUpdating()
        AppDI.shared.smoothnessEngine.start()
        // also start the ride recorder so we log to CSV
        AppDI.shared.rideRecorder.start(route: route)
        isRiding = true
    }

    func stopRide() {
        AppDI.shared.locationManager.stopUpdating()
        AppDI.shared.smoothnessEngine.stop()
        AppDI.shared.rideRecorder.stop()
        isRiding = false
    }
}

// MARK: - Overlays & scoring

private extension MapScreen {
    /// Computes per-step colors based on scoring metrics for the given route.
    /// - Parameter route: The MKRoute to score.
    /// - Returns: An array of UIColor representing the color for each step.
    func perStepColors(route: MKRoute) -> [UIColor] {
        let steps = route.steps
        guard !steps.isEmpty else { return [] }

        return steps.enumerated().map { (i, _) in
            let rough = 0.0
            let ctx = (i < stepContext.count)
                ? stepContext[i]
                : StepContext(stepIndex: i, laneBonus: 0, turnPenalty: 0, hazardPenalty: 0, tags: StepTags())

            let score = scorer.computeScore(for: route,
                                            roughnessRMS: rough,
                                            slopePenalty: slopePenalty,
                                            mode: mode,
                                            stepContext: ctx)
            return scorer.color(forScore: score)
        }
    }

    /// Recomputes overlays on the map view.
    /// Currently a placeholder for future overlay updates.
    func recomputeOverlays() {
        // No overlays to update at this time; placeholder for future implementation.
    }
}
