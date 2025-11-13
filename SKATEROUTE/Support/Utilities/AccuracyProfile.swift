// Core/AccuracyProfile.swift
// Unified accuracy + power profiles for CLLocationManager.
// Consistent with LocationManagerService.applyPowerBudget* and RideMode hints.
// Provides sensible defaults, Low Power Mode adjustments, and a one-liner `apply(to:)`.

import CoreLocation
import Foundation

/// High-level accuracy/power modes used across the app.
/// Keep the set small and opinionated so we can reason about battery and drift.
/// - navigation: tight lock for active guidance.
/// - balanced: everyday foreground use (planner, explore).
/// - monitoring: lightweight foreground background-candid eligibility (geofences + coarse GPS).
/// - background: minimal updates; rely mostly on geofences/significant-change.
public enum AccuracyProfile: String, CaseIterable, Sendable {
    case navigation
    case balanced
    case monitoring
    case background

    // MARK: Tunables (base targets before Low Power Mode adaptation)

    /// CoreLocation desired horizontal accuracy.
    public var desiredAccuracy: CLLocationAccuracy {
        switch self {
        case .navigation: return kCLLocationAccuracyBestForNavigation
        case .balanced:   return kCLLocationAccuracyNearestTenMeters
        case .monitoring: return kCLLocationAccuracyHundredMeters
        case .background: return kCLLocationAccuracyHundredMeters
        }
    }

    /// Meters moved before CoreLocation emits an update.
    public var distanceFilter: CLLocationDistance {
        switch self {
        case .navigation: return 5          // tight for turn-by-turn
        case .balanced:   return 20         // light Foreground
        case .monitoring: return 60         // reduce chatter
        case .background: return 200        // background trickle; geofences do the heavy lifting
        }
    }

    /// Activity hint to improve platform heuristics.
    public var activityType: CLActivityType {
        switch self {
        case .navigation: return .fitness    // continuous movement with frequent heading changes
        case .balanced:   return .otherNavigation
        case .monitoring: return .other
        case .background: return .other
        }
    }

    /// Whether the system may pause updates automatically.
    public var pausesAutomatically: Bool {
        switch self {
        case .navigation: return false
        case .balanced:   return true
        case .monitoring: return true
        case .background: return true
        }
    }

    /// Whether background updates should be allowed for this profile.
    public var allowsBackgroundUpdates: Bool {
        switch self {
        case .navigation: return true
        case .balanced:   return false
        case .monitoring: return true
        case .background: return true
        }
    }

    /// UI indicator when in background (only used when allowed).
    public var showsBackgroundIndicator: Bool {
        switch self {
        case .navigation: return true
        default:          return false
        }
    }

    /// Optional deferred update policy (distance, timeout). Nil = no deferral.
    /// We use this only in low-churn modes to batch updates and save power.
    public var deferredPolicy: (distance: CLLocationDistance, timeout: TimeInterval)? {
        switch self {
        case .monitoring: return (distance: 250, timeout: 60 * 5)
        case .background: return (distance: 500, timeout: 60 * 10)
        default:          return nil
        }
    }

    // MARK: Low Power Mode adaptation

    /// Apply small, safe relaxations when Low Power Mode is on.
    private func adaptForLowPower(_ accuracy: CLLocationAccuracy, _ filter: CLLocationDistance) -> (CLLocationAccuracy, CLLocationDistance) {
        guard ProcessInfo.processInfo.isLowPowerModeEnabled else { return (accuracy, filter) }
        switch self {
        case .navigation:
            // Keep guidance usable but ease the budget slightly.
            return (max(accuracy, kCLLocationAccuracyNearestTenMeters), filter * 1.3)
        case .balanced:
            return (kCLLocationAccuracyHundredMeters, filter * 1.5)
        case .monitoring, .background:
            return (kCLLocationAccuracyHundredMeters, filter * 1.7)
        }
    }

    // MARK: Integration helpers

    /// One-liner to configure a CLLocationManager for this profile.
    /// - Parameters:
    ///   - manager: The target manager.
    ///   - overrideShowsBackgroundIndicator: Optional override for `showsBackgroundLocationIndicator` (nil = use profile default).
    public func apply(to manager: CLLocationManager, overrideShowsBackgroundIndicator: Bool? = nil) {
        let (acc, filt) = adaptForLowPower(desiredAccuracy, distanceFilter)
        manager.desiredAccuracy = acc
        manager.distanceFilter = filt
        manager.activityType = activityType
        manager.pausesLocationUpdatesAutomatically = pausesAutomatically
        manager.allowsBackgroundLocationUpdates = allowsBackgroundUpdates

        if #available(iOS 11.0, *) {
            manager.showsBackgroundLocationIndicator = overrideShowsBackgroundIndicator ?? showsBackgroundIndicator
        }

        // Defensive: cancel any outstanding deferral when switching to tighter modes.
        manager.disallowDeferredLocationUpdates()
        if let policy = deferredPolicy {
            // Only attempt deferral if hardware supports it.
            if CLLocationManager.deferredLocationUpdatesAvailable() && allowsBackgroundUpdates {
                manager.allowDeferredLocationUpdates(untilTraveled: policy.distance, timeout: policy.timeout)
            }
        }
    }

    // MARK: RideMode bridge

    /// Suggest a profile for active guidance based on rider mode and its accuracy hint.
    /// `LocationManagerService` can call this to align with our ≤8%/hr budget goal.
    public static func forActiveNavigation(rideMode: RideMode) -> AccuracyProfile {
        // Tighten a bit for "fast"; keep standard for smoother/chill/night.
        switch rideMode {
        case .fastMildRoughness:
            return .navigation
        case .smoothest, .chillFewCrossings, .trickSpotCrawl, .nightSafe:
            return .navigation
        }
    }

    /// Suggest a profile for passive monitoring between rides.
    public static var forPassiveMonitoring: AccuracyProfile { .monitoring }
    /// Suggest a profile for planner/explore screens.
    public static var forPlannerBalanced: AccuracyProfile { .balanced }
    /// Suggest a profile for deep background idling.
    public static var forDeepBackground: AccuracyProfile { .background }
}

// MARK: - Convenience for LocationManaging wrappers

public extension CLLocationManager {
    /// Safe, explicit reset of deferral (wrapped for clarity).
    func disallowDeferredLocationUpdates() {
        // No-op on simulators/hardware that doesn’t support.
        self.disallowDeferredLocationUpdates()
    }
}


