// Services/Hazards/HazardAlertService.swift
// Low-power hazard geofencing + foreground banners + VoiceOver + local notifications.
// Region budget aware (<=20), throttled announcements, significant-change updates.
// No tracking; privacy-first. AppDI-friendly.

import Foundation
import CoreLocation
import Combine
import MapKit
import UserNotifications
import UIKit
import os.log

// MARK: - DI seams

public protocol HazardQuerying {
    // Return active hazards within region. HazardReport from HazardStore is fine.
    @discardableResult
    func query(in region: MKCoordinateRegion) -> [HazardReport]
    var hazardsPublisher: AnyPublisher<[HazardReport], Never> { get }
}

public protocol LocationProviding: AnyObject {
    var authorizationPublisher: AnyPublisher<CLAuthorizationStatus, Never> { get }
    var locationPublisher: AnyPublisher<CLLocation, Never> { get }
    func currentAuthorization() -> CLAuthorizationStatus
    func startSignificantLocationChanges()
    func stopSignificantLocationChanges()
}

// MARK: - Service

@MainActor
public final class HazardAlertService: NSObject, ObservableObject {

    public enum State: Equatable { case idle, active, error(String) }

    public struct Banner: Identifiable, Equatable {
        public let id = UUID()
        public let hazardId: String
        public let title: String
        public let message: String
        public let severity: Int
        public let coordinate: CLLocationCoordinate2D
        public let createdAt: Date
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var lastBanner: Banner?

    public var bannerPublisher: AnyPublisher<Banner, Never> { bannerSubject.eraseToAnyPublisher() }

    // DI
    private let hazards: HazardQuerying
    private let location: LocationProviding
    private let center: UNUserNotificationCenter
    private let logger = Logger(subsystem: "com.skateroute", category: "HazardAlertService")

    // Internals
    private let clManager = CLLocationManager() // used only for region monitoring
    private var cancellables = Set<AnyCancellable>()
    private var monitoredIds = Set<String>()
    private var lastAnnounceAt: Date = .distantPast

    // Streams
    private let bannerSubject = PassthroughSubject<Banner, Never>()

    // Policy knobs
    public struct Policy: Equatable {
        public var radiusMeters: CLLocationDistance = 120        // geofence radius
        public var regionBudget: Int = 20                         // iOS limit
        public var announceCooldown: TimeInterval = 60            // seconds between VO/banners
        public var notificationCategoryId: String = "HAZARD_NEARBY"
        public init() {}
    }
    public var policy = Policy()

    public init(hazards: HazardQuerying,
                location: LocationProviding,
                notificationCenter: UNUserNotificationCenter = .current()) {
        self.hazards = hazards
        self.location = location
        self.center = notificationCenter
        super.init()
        clManager.delegate = self
        clManager.allowsBackgroundLocationUpdates = true
        wire()
    }

    // MARK: Lifecycle

    public func start() {
        state = .active
        location.startSignificantLocationChanges()
        refreshRegionsAroundLastKnown()
    }

    public func stop() {
        state = .idle
        location.stopSignificantLocationChanges()
        clManager.monitoredRegions.forEach { clManager.stopMonitoring(for: $0) }
        monitoredIds.removeAll()
    }

    // MARK: Wiring

    private func wire() {
        // Observe auth
        location.authorizationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .authorizedAlways, .authorizedWhenInUse:
                    self.state = .active
                    self.refreshRegionsAroundLastKnown()
                case .denied, .restricted:
                    self.state = .error("Location permissions denied")
                    self.stop()
                default: break
                }
            }.store(in: &cancellables)

        // Observe location changes (significant-change manager drives this)
        location.locationPublisher
            .debounce(for: .seconds(3), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshRegionsAroundLastKnown() }
            .store(in: &cancellables)

        // Observe hazard database changes to re-budget regions when nearby set changes
        hazards.hazardsPublisher
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshRegionsAroundLastKnown() }
            .store(in: &cancellables)
    }

    // MARK: Region budgeting

    private func refreshRegionsAroundLastKnown() {
        guard state == .active else { return }
        guard let loc = try? location.locationPublisher.valueIfAvailable() ?? nil else { return }

        let region = MKCoordinateRegion(center: loc.coordinate,
                                        latitudinalMeters: 2_000,
                                        longitudinalMeters: 2_000)
        let nearby = hazards.query(in: region)

        // Sort by distance & severity to allocate limited 20 regions
        let sorted = nearby
            .sorted { a, b in
                let da = loc.distance(from: CLLocation(latitude: a.lat, longitude: a.lon))
                let db = loc.distance(from: CLLocation(latitude: b.lat, longitude: b.lon))
                if da != db { return da < db }
                return a.severity > b.severity
            }
            .prefix(policy.regionBudget)

        // Build target set
        let targetIds = Set(sorted.map(\.id))

        // Stop ones we no longer want
        for r in clManager.monitoredRegions {
            guard let region = r as? CLCircularRegion else { continue }
            if !targetIds.contains(region.identifier) {
                clManager.stopMonitoring(for: region)
                monitoredIds.remove(region.identifier)
            }
        }

        // Start new ones
        for h in sorted where !monitoredIds.contains(h.id) {
            let cr = CLCircularRegion(center: h.coordinate,
                                      radius: max(50, min(policy.radiusMeters, clManager.maximumRegionMonitoringDistance)),
                                      identifier: h.id)
            cr.notifyOnEntry = true
            cr.notifyOnExit = false
            clManager.startMonitoring(for: cr)
            monitoredIds.insert(h.id)
        }
    }

    // MARK: Announcements

    private func announceForeground(for hazard: HazardReport, distance: CLLocationDistance?) {
        let now = Date()
        guard now.timeIntervalSince(lastAnnounceAt) >= policy.announceCooldown else { return }
        lastAnnounceAt = now

        let title = hazardTitle(hazard)
        let msg: String = {
            if let d = distance { return localized("hazard_nearby_with_distance", args: [hazard.kind.rawValue, formatMeters(d)]) }
            return localized("hazard_nearby", args: [hazard.kind.rawValue])
        }()

        let banner = Banner(hazardId: hazard.id,
                            title: title,
                            message: msg,
                            severity: hazard.severity,
                            coordinate: hazard.coordinate,
                            createdAt: now)
        lastBanner = banner
        bannerSubject.send(banner)

        // VO announcement for accessibility
        UIAccessibility.post(notification: .announcement, argument: msg)
    }

    private func scheduleLocalNotification(for hazard: HazardReport) {
        let content = UNMutableNotificationContent()
        content.title = hazardTitle(hazard)
        content.body = localized("hazard_notification_body", args: [hazard.kind.rawValue])
        content.sound = .default
        content.categoryIdentifier = policy.notificationCategoryId
        content.userInfo = ["hazardId": hazard.id]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let req = UNNotificationRequest(identifier: "hazard-\(hazard.id)-\(UUID().uuidString)", content: content, trigger: trigger)
        center.add(req) { [weak self] err in
            if let e = err { self?.logger.error("Local notification error: \(e.localizedDescription, privacy: .public)") }
        }
    }

    private func hazardTitle(_ h: HazardReport) -> String {
        switch h.kind {
        case .pothole: return localized("hazard_title_pothole")
        case .gravel:  return localized("hazard_title_gravel")
        case .rail:    return localized("hazard_title_rail")
        case .crack:   return localized("hazard_title_crack")
        case .debris:  return localized("hazard_title_debris")
        case .wet:     return localized("hazard_title_wet")
        case .other:   return localized("hazard_title_other")
        }
    }

    private func formatMeters(_ m: CLLocationDistance) -> String {
        if m < 100 { return String(format: "%.0f m", m) }
        return String(format: "%.0f m", round(m / 10) * 10)
    }

    private func localized(_ key: String, args: [CVarArg] = []) -> String {
        let tmpl = NSLocalizedString(key, comment: "")
        return String(format: tmpl, arguments: args)
    }
}

// MARK: - CLLocationManagerDelegate

extension HazardAlertService: CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let id = (region as? CLCircularRegion)?.identifier else { return }
        // Pull hazard details from latest cache
        guard let hazard = hazards.hazardsPublisher.latestSnapshot()?.first(where: { $0.id == id }) else { return }

        // Foreground vs background behavior
        if UIApplication.shared.applicationState == .active {
            let here = (try? location.locationPublisher.valueIfAvailable())?.coordinate
            let d: CLLocationDistance? = here.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: CLLocation(latitude: hazard.lat, longitude: hazard.lon)) }
            announceForeground(for: hazard, distance: d)
        } else {
            scheduleLocalNotification(for: hazard)
        }
    }

    public func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        logger.error("Region monitoring failed: \(error.localizedDescription, privacy: .public)")
    }

    public func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        // handled via LocationProviding authorizationPublisher; keep for completeness
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            refreshRegionsAroundLastKnown()
        }
    }
}

// MARK: - Small helpers (Combine QoL)

private extension AnyPublisher where Output == CLLocation, Failure == Never {
    func valueIfAvailable() throws -> CLLocation? {
        var latest: CLLocation?
        let sem = DispatchSemaphore(value: 0)
        let c = self.prefix(1).sink { _ in } receiveValue: { loc in latest = loc; sem.signal() }
        sem.wait(timeout: .now() + 0.01)
        withExtendedLifetime(c) {}
        return latest
    }
}

private extension AnyPublisher where Output == [HazardReport], Failure == Never {
    func latestSnapshot() -> [HazardReport]? {
        var latest: [HazardReport]?
        let sem = DispatchSemaphore(value: 0)
        let c = self.prefix(1).sink { _ in } receiveValue: { arr in latest = arr; sem.signal() }
        sem.wait(timeout: .now() + 0.01)
        withExtendedLifetime(c) {}
        return latest
    }
}
