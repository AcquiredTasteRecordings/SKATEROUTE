// Services/LocationManagerService.swift
import Foundation
import CoreLocation
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
public final class LocationManagerService: NSObject, ObservableObject, @MainActor CLLocationManagerDelegate {
    /// The current location of the device.
    @Published public var currentLocation: CLLocation?
    /// The current authorization status for location services.
    @Published public var authorization: CLAuthorizationStatus = .notDetermined
    /// Whether the service is actively updating location.
    @Published public private(set) var isTracking: Bool = false

    private let manager = CLLocationManager()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SKATEROUTE", category: "LocationManagerService")

    /// Supported accuracy profiles for location tracking.
    public enum AccuracyProfile {
        /// Eco mode: lower accuracy, larger distance filter, optimized for battery saving.
        case eco
        /// Balanced mode: moderate accuracy and distance filter.
        case balanced
        /// Precision mode: highest accuracy and smallest distance filter for detailed tracking.
        case precision

        /// Desired accuracy value for CLLocationManager.
        var desiredAccuracy: CLLocationAccuracy {
            switch self {
            case .eco:
                return kCLLocationAccuracyHundredMeters
            case .balanced:
                return kCLLocationAccuracyNearestTenMeters
            case .precision:
                return kCLLocationAccuracyBestForNavigation
            }
        }

        /// Distance filter in meters.
        var distanceFilter: CLLocationDistance {
            switch self {
            case .eco:
                return 50.0
            case .balanced:
                return 10.0
            case .precision:
                return kCLDistanceFilterNone
            }
        }

        /// Appropriate activity type for CLLocationManager.
        var activityType: CLActivityType {
            switch self {
            case .eco:
                return .otherNavigation
            case .balanced:
                return .fitness
            case .precision:
                return .fitness
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
        didSet {
            adaptBackgroundLocationUpdates()
        }
    }

    private var motionManager: CMMotionActivityManager?

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

        // Observe battery state changes to adapt background updates
        NotificationCenter.default.addObserver(self, selector: #selector(batteryStateDidChange), name: UIDevice.batteryStateDidChangeNotification, object: nil)
        UIDevice.current.isBatteryMonitoringEnabled = true

        startMotionUpdates()
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: UIDevice.batteryStateDidChangeNotification, object: nil)
        stopMotionUpdates()
    }

    /// Apply a predefined accuracy profile to configure location updates.
    /// - Parameter profile: The desired accuracy profile.
    public func applyAccuracy(_ profile: AccuracyProfile) {
        currentProfile = profile
        manager.desiredAccuracy = profile.desiredAccuracy
        manager.distanceFilter = profile.distanceFilter
        manager.activityType = profile.activityType
        logger.log("Applied accuracy profile: \(String(describing: profile))")
    }

    /// Start continuous location updates associated with a specific ride session.
    /// This method enables detailed logging for debugging and route attribution.
    /// - Parameter sessionID: The identifier of the ride session.
    public func beginContinuousTracking(for sessionID: String) {
        logger.log("Beginning continuous tracking for session: \(sessionID)")
        startUpdating()
        isTracking = true
    }

    /// Starts high-quality location updates suitable for active navigation (with background allowed).
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
            // Foreground-only unless Info.plist and Always auth are present
            manager.allowsBackgroundLocationUpdates = false
            logger.log("Authorized WhenInUse - background updates disabled")
        case .authorizedAlways:
            // Allow background only if Info.plist declares it
            manager.allowsBackgroundLocationUpdates = allowsBackground
            logger.log("Authorized Always - background updates set to \(self.allowsBackground)")
        @unknown default:
            manager.allowsBackgroundLocationUpdates = false
            logger.log("Unknown authorization status - background updates disabled")
        }

        adaptBackgroundLocationUpdates()

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
        manager.allowsBackgroundLocationUpdates = false
        isTracking = false
    }

    /// Requests temporary full-accuracy location if the app currently has reduced accuracy.
    /// - Parameter purposeKey: The purpose key describing why full accuracy is needed.
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

    // MARK: - CLLocationManagerDelegate

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        logger.log("Authorization status changed to: \(self.authorization.rawValue)")
        if authorization == .authorizedAlways || authorization == .authorizedWhenInUse {
            // Optionally restart updates if authorization granted
            if isTracking {
                startUpdating()
            }
        } else {
            stopUpdating()
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        currentLocation = location
        logger.log("Updated location: lat \(location.coordinate.latitude), lon \(location.coordinate.longitude), accuracy \(location.horizontalAccuracy)m")
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        logger.error("Location manager failed with error: \(error.localizedDescription)")
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

    private func stopMotionUpdates() {
        motionManager?.stopActivityUpdates()
        motionManager = nil
    }
}
