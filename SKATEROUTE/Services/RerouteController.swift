// Services/RerouteController.swift
import Foundation
import MapKit
import CoreLocation
import Combine

/// Observes location drift relative to the active navigation route and triggers reroute requests.
@MainActor
public final class RerouteController: ObservableObject {
    private let locationService: LocationManagerService
    private var cancellables: Set<AnyCancellable> = []
    private var currentRoute: MKRoute?
    private var offRouteHandler: ((CLLocationCoordinate2D) -> Void)?
    private var lastRerouteDate: Date?
    private let offRouteThreshold: CLLocationDistance = 40
    private let rerouteCooldown: TimeInterval = 30

    public init(locationService: LocationManagerService = AppDI.shared.locationManager) {
        self.locationService = locationService
    }

    public func startMonitoring(route: MKRoute,
                                onOffRoute: @escaping (CLLocationCoordinate2D) -> Void) {
        stopMonitoring()
        currentRoute = route
        offRouteHandler = onOffRoute
        lastRerouteDate = nil

        locationService.applyPowerBudgetForMonitoring()
        locationService.installGeofences(along: route)

        locationService.geofenceEventHandler = { [weak self] event in
            guard let self else { return }
            switch event {
            case .entered:
                break
            case .exited(let region):
                self.logger("Exited geofence \(region.identifier)")
                if let location = self.locationService.currentLocation {
                    self.evaluateOffRoute(location)
                }
            }
        }

        locationService.$currentLocation
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] location in
                self?.evaluateOffRoute(location)
            }
            .store(in: &cancellables)
    }

    public func stopMonitoring() {
        cancellables.removeAll()
        locationService.geofenceEventHandler = nil
        locationService.clearGeofences()
        currentRoute = nil
        offRouteHandler = nil
        lastRerouteDate = nil
        locationService.applyAccuracy(.balanced)
    }

    public func updateRoute(_ route: MKRoute) {
        currentRoute = route
        locationService.installGeofences(along: route)
    }

    public func markRouteStabilized() {
        locationService.applyPowerBudgetForMonitoring()
    }

    private func evaluateOffRoute(_ location: CLLocation) {
        guard let route = currentRoute else { return }
        guard shouldTriggerReroute(now: Date()) else { return }
        let distance = distanceToRoute(location, route: route)
        if distance > offRouteThreshold {
            lastRerouteDate = Date()
            locationService.applyPowerBudgetForActiveNavigation()
            offRouteHandler?(location.coordinate)
        }
    }

    private func shouldTriggerReroute(now: Date) -> Bool {
        guard let last = lastRerouteDate else { return true }
        return now.timeIntervalSince(last) > rerouteCooldown
    }

    private func distanceToRoute(_ location: CLLocation, route: MKRoute) -> CLLocationDistance {
        let coords = route.polyline.coordinates()
        guard !coords.isEmpty else { return .greatestFiniteMagnitude }
        var best = CLLocationDistance.greatestFiniteMagnitude
        for coord in coords {
            let candidate = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            let distance = location.distance(from: candidate)
            if distance < best { best = distance }
        }
        return best
    }

    private func logger(_ message: String) {
        print("[RerouteController] \(message)")
    }
}
