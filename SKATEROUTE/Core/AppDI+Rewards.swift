//  AppDI+Rewards.swift
//  SKATEROUTE
//
//  Rewards DI hub: chooses the best available persistence backend (Firestore → CloudKit → UserDefaults),
//  exposes a single shared RewardsManager, supports test/preview overrides, and offers a SwiftUI
//  Environment hook. All side-effects (bootstrap, opportunistic persistence) are main-actor safe.

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
public enum RewardsDI {
    // Optional override for tests/previews. If set, it is returned instead of the shared instance.
    private static var _override: RewardsManager?

    /// Canonical access point used across the app. Prefer injecting via Environment when possible.
    public static var manager: RewardsManager {
        if let o = _override { return o }
        return _shared
    }

    // MARK: - Construction

    private static let _shared: RewardsManager = {
        // Always-available local store
        let local = UserDefaultsRewardsStore()

        // Optional secondaries (compile-gated)
        #if canImport(CloudKit)
        let ck: RewardsStore? = CloudKitRewardsStore()
        #else
        let ck: RewardsStore? = nil
        #endif

        #if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        let fs: RewardsStore? = FirestoreRewardsStore()
        #else
        let fs: RewardsStore? = nil
        #endif

        // Prefer remote as primary when present, else local. Keep a backup for redundancy.
        let primary: RewardsStore = fs ?? ck ?? local
        let backup: RewardsStore? = (primary is UserDefaultsRewardsStore) ? (ck ?? fs) : local

        let mgr = RewardsManager(primary: primary, backup: backup)
        Task { await mgr.bootstrap() }

        // Opportunistic persistence on app lifecycle transitions (best-effort, non-fatal)
        #if canImport(UIKit) && !os(watchOS)
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let snapshot = mgr.wallet
                try? await primary.save(snapshot)
                if let backup { try? await backup.save(snapshot) }
            }
        }
        #endif

        return mgr
    }()

    /// Override the shared manager (e.g., in unit tests or SwiftUI previews). Pass `nil` to clear.
    public static func useOverride(_ manager: RewardsManager?) {
        _override = manager
    }
}

// MARK: - SwiftUI Environment integration

private struct RewardsManagerKey: EnvironmentKey {
    static let defaultValue: RewardsManager = RewardsDI.manager
}

public extension EnvironmentValues {
    /// Access the shared RewardsManager via SwiftUI's Environment.
    var rewardsManager: RewardsManager {
        get { self[RewardsManagerKey.self] }
        set { self[RewardsManagerKey.self] = newValue }
    }
}

// MARK: - Preview seeding helpers (no-ops in production)

public enum RewardsPreview {
    /// Create a throwaway RewardsManager seeded with some demo data for SwiftUI previews.
    @MainActor
    public static func sampleManager() -> RewardsManager {
        let mgr = RewardsManager(primary: UserDefaultsRewardsStore())
        // Seed with representative activity using public APIs only
        try? mgr.earn(.distanceKm(8.2))
        try? mgr.earn(.hazardReport(quality: 2))
        mgr.awardBadge("founder_001")
        return mgr
    }
}


