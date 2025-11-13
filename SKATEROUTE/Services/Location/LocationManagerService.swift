// Services/LocationManagerService.swift
import Foundation
import CoreLocation
import MapKit
import os
import UIKit
import CoreMotion

/**
 `LocationManagerService` is a central service responsible for managing location updates within SKATEROUTE,
 integrating tightly with the app's ride tracking and navigation features.

 This service provides real-time location data used to track rides, calculate routes, and provide turn-by-turn navigation.
 It supports configurable accuracy tiers to balance battery consumption against location precision, and adapts background
 location update permissions based on device battery state and user motion to optimize performance and power usage.

 ### Integration with SKATEROUTE Ride Tracking & Navigation
 - Provides continuous location updates to track user's route during rides.
 - Supports temporary full accuracy requests for critical navigation moments requiring precise location.
 - Supports background location updates when appropriate, enabling tracking even when the app is in the background.
 - Logs location and authorization changes for diagnostics and debugging.
 - Associates location updates with specific ride sessions via `beginContinuousTracking(for:)`.

 ### Accuracy Profiles
 The service supports three configurable accuracy tiers:
 - `eco`: Optimized for battery savings with reduced accuracy and larger distance filters.
 - `balanced`: Default profile balancing accuracy and battery usage.
 - `precision`: High accuracy suitable for detailed navigation and route recording.

 These profiles adjust the CLLocationManager's desiredAccuracy, distanceFilter, and activityType accordingly.

 */
@MainActor
public final class LocationManagerService: NSObject, ObservableObject, CLLocationManagerDelegate {
    private enum Mode { case monitoring, activeNavigation } // transport mode for budgeting
    private var mode: Mode = .monitoring

    /// The current location of the device.
    @Published public var currentLocation: CLLocation?
    /// The current authorization status for location services.
    @Published public var authorization: CLAuthorizationStatus = .notDetermined
    /// Whether the service is actively updating location.
    @Published public private(set) var isTracking: Bool = false

    private let manager = CLLocationManager()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SKATEROUTE", category: "LocationManagerService")

    public enum GeofenceEvent {
        case entered(CLRegion)
        case exited(CLRegion)
    }
    public var geofenceEventHandler: ((GeofenceEvent) -> Void)?

    /// Supported accuracy profiles for location tracking.
    public enum AccuracyProfile {
        case eco
        case balanced
        case precision

        var desiredAccuracy: CLLocationAccuracy {
            switch self {
            case .eco: return kCLLocationAccuracyHundredMeters
            case .balanced: return kCLLocationAccuracyNearestTenMeters
            case .precision: return kCLLocationAccuracyBestForNavigation
            }
        }

        var distanceFilter: CLLocationDistance {
            switch self {
            case .eco: return 50.0
            case .balanced: return 10.0
            case .precision: return kCLDistanceFilterNone
            }
        }

        var activityType: CLActivityType {
            switch self {
            case .eco: return .otherNavigation
            case .balanced: return .fitness
            case .precision: return .fitness
            }
        }
    }

    private var currentProfile: AccuracyProfile = .balanced

    private var allowsBackground: Bool {
        if let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] {
            return modes.contains("location")
        }
        return false
    }

    private var batteryState: UIDevice.BatteryState {
        UIDevice.current.isBatteryMonitoringEnabled = true
        return UIDevice.current.batteryState
    }

    private var isDeviceMoving: Bool = false {
        didSet { adaptBackgroundLocationUpdates() }
    }

    private var motionManager: CMMotionActivityManager?
    private let defaults = UserDefaults.standard
    private let lastLocationKey = "LocationManagerService.lastLocation"
    private let lastLocationTimestampKey = "LocationManagerService.lastLocation.timestamp"
    private var monitoredRegions: [CLCircularRegion] = []

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = currentProfile.desiredAccuracy
        manager.distanceFilter = currentProfile.distanceFilter
        manager.pausesLocationUpdatesAutomatically = true
        manager.activityType = currentProfile.activityType
        manager.allowsBackgroundLocationUpdates = false
        if #available(iOS 11.0, *) { manager.showsBackgroundLocationIndicator = false }
        manager.requestWhenInUseAuthorization()

        NotificationCenter.default.addObserver(self, selector: #selector(batteryStateDidChange), name: UIDevice.batteryStateDidChangeNotification, object: nil)
        UIDevice.current.isBatteryMonitoringEnabled = true

        startMotionUpdates()
        restoreLastKnownLocation()
    }

    @MainActor
    deinit {
        NotificationCenter.default.removeObserver(self, name: UIDevice.batteryStateDidChangeNotification, object: nil)
        stopMotionUpdates()
    }

    // MARK: - Profiles & Budgets

    public func applyAccuracy(_ profile: AccuracyProfile) {
        currentProfile = profile
        manager.desiredAccuracy = profile.desiredAccuracy
        manager.distanceFilter = profile.distanceFilter
        manager.activityType = profile.activityType
        logger.log("Applied accuracy profile: \(String(describing: profile))")
    }

    /// Low-power budget for passive monitoring (<8%/hr target).
    public func applyPowerBudgetForMonitoring() {
        // Low-power: prefer significant-change updates when app is idle / passive monitoring.
        applyAccuracy(.eco)
        manager.pausesLocationUpdatesAutomatically = true
        manager.distanceFilter = max(25, currentProfile.distanceFilter)
        mode = .monitoring
        switchToSignificantChangeIfPossible()
        logger.log("Applied monitoring power budget (eco + significant changes)")
    }

    /// High-accuracy budget for active navigation and reroute recovery.
    public func applyPowerBudgetForActiveNavigation() {
        // High accuracy for on-route guidance and reroute detection.
        applyAccuracy(.precision)
        manager.pausesLocationUpdatesAutomatically = true
        manager.distanceFilter = kCLDistanceFilterNone
        mode = .activeNavigation
        switchToStandardLocationUpdates()
        logger.log("Applied active-navigation power budget (precision updates)")
    }

    // MARK: - Start/Stop

    /// Start continuous location updates associated with a specific ride session.
    public func beginContinuousTracking(for sessionID: String) {
        logger.log("Beginning continuous tracking for session: \(sessionID)")
        startUpdating()
        isTracking = true
    }

    /// Starts location updates considering current mode & authorization.
    public func startUpdating() {
        logger.log("Starting location updates")
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            logger.log("Authorization not determined, requesting WhenInUseAuthorization")
            return
        case .restricted, .denied:
            logger.error("Location authorization denied or restricted")
            isTracking = false
            return
        case .authorizedWhenInUse:
            manager.allowsBackgroundLocationUpdates = false
            logger.log("Authorized WhenInUse - background updates disabled")
        case .authorizedAlways:
            manager.allowsBackgroundLocationUpdates = allowsBackground
            logger.log("Authorized Always - background updates set to \(self.allowsBackground)")
        @unknown default:
            manager.allowsBackgroundLocationUpdates = false
            logger.log("Unknown authorization status - background updates disabled")
        }

        adaptBackgroundLocationUpdates()

        // Respect monitoring mode: prefer significant-change transport.
        if mode == .monitoring {
            switchToSignificantChangeIfPossible()
            return
        }

        manager.pausesLocationUpdatesAutomatically = true
        manager.activityType = currentProfile.activityType
        manager.desiredAccuracy = currentProfile.desiredAccuracy
        manager.distanceFilter = currentProfile.distanceFilter
        manager.startUpdatingLocation()
        isTracking = true
    }

    /// Stops location updates.
    public func stopUpdating() {
        logger.log("Stopping location updates")
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = false
        isTracking = false
    }

    // MARK: - Accuracy Request

    public func requestTemporaryFullAccuracyIfNeeded(purposeKey: String) {
        if #available(iOS 14.0, *) {
            if manager.accuracyAuthorization == .reducedAccuracy {
                logger.log("Requesting temporary full accuracy for purpose: \(purposeKey)")
                manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: purposeKey) { error in
                    if let error = error {
                        self.logger.error("Temporary full accuracy request failed: \(error.localizedDescription)")
                    } else {
                        self.logger.log("Temporary full accuracy granted")
                    }
                }
            }
        }
    }

    // MARK: - Route Geofencing

    /// Installs circular geofences along a route to detect off-route drift when in the background.
    public func installGeofences(along route: MKRoute,
                                 radius: CLLocationDistance = 35,
                                 spacing: CLLocationDistance = 120) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            logger.log("Geofencing unavailable on this device")
            return
        }
        guard authorization == .authorizedAlways else {
            logger.log("Geofence install skipped: requires Authorized Always")
            return
        }
        // Remove previously installed route geofences to avoid exceeding limits
        clearGeofences()

        let coords = route.polyline.coordinates()
        guard !coords.isEmpty else { return }

        var lastSample = coords.first!
        var accumulated: CLLocationDistance = 0
        var index = 0
        let maxRegions = 19 // keep one slot free for any ad-hoc region elsewhere

        for coord in coords {
            guard monitoredRegions.count < maxRegions else { break }
            let distance = CLLocation(latitude: lastSample.latitude, longitude: lastSample.longitude)
                .distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
            accumulated += distance
            if index == 0 || accumulated >= spacing {
                accumulated = 0
                lastSample = coord
                let identifier = "route-geofence-\(Int(route.expectedTravelTime))-\(index)"
                let region = CLCircularRegion(center: coord,
                                              radius: max(25, radius),
                                              identifier: identifier)
                region.notifyOnExit = true
                region.notifyOnEntry = false
                manager.startMonitoring(for: region)
                monitoredRegions.append(region)
                logger.log("Installed geofence \(identifier) @lat \(coord.latitude, privacy: .public), lon \(coord.longitude, privacy: .public)")
                index += 1
            }
        }
    }

    /// Clears all monitored route geofences (only those created by us).
    public func clearGeofences() {
        // Stop regions we created and any stray ones with our prefix.
        let prefix = "route-geofence-"
        let all = Array(manager.monitoredRegions)
        for region in all where region.identifier.hasPrefix(prefix) {
            manager.stopMonitoring(for: region)
        }
        for region in monitoredRegions {
            manager.stopMonitoring(for: region)
        }
        monitoredRegions.removeAll()
    }

    // MARK: - CLLocationManagerDelegate

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        logger.log("Authorization status changed to: \(self.authorization.rawValue)")
        if authorization == .authorizedAlways || authorization == .authorizedWhenInUse {
            if isTracking { startUpdating() } // restart if we were tracking
        } else {
            stopUpdating()
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        currentLocation = location
        logger.log("Updated location: lat \(location.coordinate.latitude), lon \(location.coordinate.longitude), accuracy \(location.horizontalAccuracy)m")
        persistLastLocation(location)
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        logger.error("Location manager failed with error: \(error.localizedDescription)")
    }

    public func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        logger.log("Entered geofence: \(region.identifier)")
        geofenceEventHandler?(.entered(region))
    }

    public func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        logger.log("Exited geofence: \(region.identifier)")
        geofenceEventHandler?(.exited(region))
    }

    // MARK: - Update Transport Switching

    private func switchToSignificantChangeIfPossible() {
        // Stop standard updates first to avoid double streams.
        manager.stopUpdatingLocation()
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        } else {
            // Fall back to coarse standard updates.
            manager.startUpdatingLocation()
        }
        isTracking = true
    }

    private func switchToStandardLocationUpdates() {
        // Stop significant-change updates if active.
        manager.stopMonitoringSignificantLocationChanges()
        // Start high-fidelity updates for navigation.
        manager.startUpdatingLocation()
        isTracking = true
    }

    // MARK: - Adaptive Background Location Updates

    private func adaptBackgroundLocationUpdates() {
        // Enable background location updates only if:
        // - Authorization is Always
        // - Info.plist allows background location
        // - Device is moving
        // - Battery state is not low (not unplugged and below 20%)
        let batteryLevel = UIDevice.current.batteryLevel
        let lowBattery = batteryLevel >= 0 && batteryLevel < 0.20 && batteryState == .unplugged

        let shouldAllowBackground = authorization == .authorizedAlways &&
            allowsBackground &&
            isDeviceMoving &&
            !lowBattery

        if manager.allowsBackgroundLocationUpdates != shouldAllowBackground {
            manager.allowsBackgroundLocationUpdates = shouldAllowBackground
            if #available(iOS 11.0, *) {
                manager.showsBackgroundLocationIndicator = shouldAllowBackground && mode == .activeNavigation
            }
            logger.log("Adaptive background location updates set to \(shouldAllowBackground)")
        }
    }

    // MARK: - Battery & Motion Monitoring

    @objc private func batteryStateDidChange() {
        logger.log("Battery state changed: \(self.batteryState.rawValue)")
        adaptBackgroundLocationUpdates()
    }

    private func startMotionUpdates() {
        guard CMMotionActivityManager.isActivityAvailable() else {
            logger.log("Motion activity not available on this device")
            return
        }
        motionManager = CMMotionActivityManager()
        motionManager?.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self = self, let activity = activity else { return }
            let moving = activity.walking || activity.running || activity.cycling || activity.automotive
            if self.isDeviceMoving != moving {
                self.isDeviceMoving = moving
                self.logger.log("Device motion state changed: isMoving = \(moving)")
            }
        }
    }

    nonisolated(unsafe) private func stopMotionUpdates() {
        motionManager?.stopActivityUpdates()
        motionManager = nil
    }

    // MARK: - Last Known Location Cache

    private func restoreLastKnownLocation() {
        guard let stored = defaults.dictionary(forKey: lastLocationKey) as? [String: Double],
              let lat = stored["lat"],
              let lon = stored["lon"] else { return }
        let location = CLLocation(latitude: lat, longitude: lon)
        currentLocation = location
        logger.log("Restored cached location: lat \(lat), lon \(lon)")
    }

    private func persistLastLocation(_ location: CLLocation) {
        let payload = ["lat": location.coordinate.latitude, "lon": location.coordinate.longitude]
        defaults.set(payload, forKey: lastLocationKey)
        defaults.set(location.timestamp.timeIntervalSince1970, forKey: lastLocationTimestampKey)
    }
}


