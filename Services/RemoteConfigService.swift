// Services/RemoteConfigService.swift
// Soft switches (Firebase RC if enabled; no PII). Type-safe keys, cache TTL, stale fallback.
// Order of truth: in-memory → fresh disk cache → Firebase (if enabled) → bundled JSON → hardcoded defaults.
//
// Privacy: never sends PII; fetches are anonymous. Opt-ins are local-only.
//
// Integration points already used elsewhere:
//  • PaywallRules: frequency caps, cold-start gating.
//  • Media: editor export presets.
//  • Profile: isProfileCloudSyncEnabled (opt-in is stored locally, not remote).
//  • Speech/Alerts: VO cadence, hazard geofence radius.
//  • Offline tiles: default corridor buffer.

import Foundation
import Combine
import os.log

#if canImport(FirebaseRemoteConfig)
import FirebaseRemoteConfig
#endif

// MARK: - Public protocol (narrow seam used by other services)

public protocol RemoteConfigServing {
    // Existing properties referenced by other modules (UserProfileStore et al)
    var isProfileCloudSyncEnabled: Bool { get }  // remote toggle
    var isProfileCloudOptIn: Bool { get }        // **local** user choice (no PII upload)
}

// MARK: - Type-safe keys

public struct RCKey<T: RCDecodable>: Hashable, Sendable {
    public let raw: String
    public let defaultValue: T
    public init(_ raw: String, default defaultValue: T) {
        self.raw = raw
        self.defaultValue = defaultValue
    }
}

public protocol RCDecodable {
    static func decode(from any: Any) -> Self?
}

extension Bool: RCDecodable { public static func decode(from any: Any) -> Bool? { any as? Bool ?? (any as? NSNumber)?.boolValue } }
extension Int: RCDecodable { public static func decode(from any: Any) -> Int? { (any as? NSNumber)?.intValue ?? Int("\(any)") }
}
extension Double: RCDecodable { public static func decode(from any: Any) -> Double? { (any as? NSNumber)?.doubleValue ?? Double("\(any)") } }
extension String: RCDecodable { public static func decode(from any: Any) -> String? { any as? String }
}
extension Array: RCDecodable where Element == String {
    public static func decode(from any: Any) -> [String]? {
        if let a = any as? [String] { return a }
        if let s = any as? String { return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        return nil
    }
}

// MARK: - Canonical keys used across the app

public enum RCKeys {
    // Growth / Paywall
    public static let paywallMaxInterstitialsPer3Sessions = RCKey<Int>("paywall.max_interstitials_per_3_sessions", default: 1)
    public static let paywallColdStartGateAfterFirstRide   = RCKey<Bool>("paywall.cold_start_after_first_ride", default: true)
    public static let paywallSuppressAfterFailedPurchase   = RCKey<Bool>("paywall.suppress_after_failed_purchase", default: true)

    // Profile sync
    public static let profileCloudSyncEnabled = RCKey<Bool>("profile.cloud_sync_enabled", default: false)

    // Media / Editor
    public static let editorExportPresets = RCKey<[String]>("editor.export_presets", default: ["feed_720p_30", "story_1080x1920_30", "archive_1080p_60"])

    // Hazards / Alerts
    public static let hazardGeofenceRadiusMeters = RCKey<Double>("hazard.geofence_radius_m", default: 120)

    // Voice
    public static let speechCadenceThrottleSec = RCKey<Double>("speech.cadence_throttle_sec", default: 1.2)

    // Offline tiles
    public static let offlineCorridorBufferMeters = RCKey<Double>("offline.corridor_buffer_m", default: 150)

    // Referrals
    public static let referralsDailyAwardCap = RCKey<Int>("referrals.daily_award_cap", default: 10)
}

// MARK: - Snapshot model (immutable, published)

public struct RemoteConfigSnapshot: Sendable {
    public let values: [String: Any] // JSON-safe leaf values only
    public let fetchedAt: Date
    public let ttlSeconds: TimeInterval

    public func value<T: RCDecodable>(for key: RCKey<T>) -> T {
        if let raw = values[key.raw], let v = T.decode(from: raw) { return v }
        return key.defaultValue
    }
}

// MARK: - Service

@MainActor
public final class RemoteConfigService: ObservableObject, RemoteConfigServing {

    public enum State: Equatable { case idle, ready, error(String) }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var snapshot: RemoteConfigSnapshot

    public var snapshotPublisher: AnyPublisher<RemoteConfigSnapshot, Never> { $snapshot.eraseToAnyPublisher() }

    // RemoteConfigServing adapter (profile sync + local opt-in)
    public var isProfileCloudSyncEnabled: Bool { snapshot.value(for: RCKeys.profileCloudSyncEnabled) }
    public var isProfileCloudOptIn: Bool { UserDefaults.standard.bool(forKey: Self.udkProfileOptIn) }

    // Config
    public struct Config: Equatable {
        public var cacheTTLSeconds: TimeInterval = 6 * 3600
        public var bundledJSONName: String = "RemoteConfigDefaults" // Resources/RemoteConfigDefaults.json
        public var firebaseEnabled: Bool = false                   // disable by default
        public init() {}
    }
    public var config: Config

    // Persistence (disk cache)
    private let cacheURL: URL
    private let log = Logger(subsystem: "com.skateroute", category: "RemoteConfig")

    // Firebase (optional)
    #if canImport(FirebaseRemoteConfig)
    private var remoteConfig: RemoteConfig?
    #endif

    // MARK: Init

    public init(config: Config = .init()) {
        self.config = config

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RemoteConfig", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheURL = dir.appendingPathComponent("cache.json")

        // Seed snapshot: disk → bundle → defaults
        let seeded = Self.loadDiskCache(from: cacheURL) ??
                     Self.loadBundledJSON(named: config.bundledJSONName) ??
                     Self.defaultSnapshot(ttl: config.cacheTTLSeconds)
        self.snapshot = seeded
        self.state = .ready

        #if canImport(FirebaseRemoteConfig)
        if config.firebaseEnabled {
            self.remoteConfig = RemoteConfig.remoteConfig()
            let settings = RemoteConfigSettings()
            settings.minimumFetchInterval = 60 // client-side; we still respect our own TTL
            self.remoteConfig?.configSettings = settings
        }
        #endif
    }

    // MARK: Public API

    /// Refresh if stale; no-op if cache TTL not expired. Returns the active snapshot.
    @discardableResult
    public func refreshIfStale(now: Date = Date()) async -> RemoteConfigSnapshot {
        let age = now.timeIntervalSince(snapshot.fetchedAt)
        guard age >= snapshot.ttlSeconds else { return snapshot }

        // Try Firebase → fallback to bundle → keep disk
        #if canImport(FirebaseRemoteConfig)
        if config.firebaseEnabled, let rc = remoteConfig {
            do {
                try await rc.fetchAndActivate()
                let merged = snapshotMergingFirebase(rc: rc, ttl: config.cacheTTLSeconds, now: now)
                apply(merged, source: "firebase")
                return merged
            } catch {
                log.notice("Firebase RC fetch failed: \(error.localizedDescription, privacy: .public)")
                // fall through to bundle
            }
        }
        #endif

        if let bundled = Self.loadBundledJSON(named: config.bundledJSONName, now: now, ttl: config.cacheTTLSeconds) {
            apply(bundled, source: "bundle")
            return bundled
        }

        // Nothing fresher; keep current snapshot
        return snapshot
    }

    /// Force reload from all sources in order (Firebase if enabled → bundle), overriding TTL.
    @discardableResult
    public func forceRefresh(now: Date = Date()) async -> RemoteConfigSnapshot {
        #if canImport(FirebaseRemoteConfig)
        if config.firebaseEnabled, let rc = remoteConfig {
            do {
                try await rc.fetchAndActivate()
                let merged = snapshotMergingFirebase(rc: rc, ttl: config.cacheTTLSeconds, now: now)
                apply(merged, source: "firebase")
                return merged
            } catch {
                log.notice("Firebase RC force fetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif
        if let bundled = Self.loadBundledJSON(named: config.bundledJSONName, now: now, ttl: config.cacheTTLSeconds) {
            apply(bundled, source: "bundle")
            return bundled
        }
        return snapshot
    }

    /// Strongly-typed read.
    public func value<T: RCDecodable>(_ key: RCKey<T>) -> T {
        snapshot.value(for: key)
    }

    /// Update the LOCAL user opt-in for profile sync (never uploaded).
    public func setProfileCloudOptIn(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.udkProfileOptIn)
        // No state publish needed; readers check UserDefaults on demand via property.
    }

    // MARK: Internals

    private func apply(_ new: RemoteConfigSnapshot, source: String) {
        snapshot = new
        Self.saveDiskCache(new, to: cacheURL)
        log.debug("Applied RC snapshot from \(source, privacy: .public) at \(String(describing: new.fetchedAt), privacy: .public)")
        state = .ready
    }

    // Merge Firebase values (strings/numbers/bools/JSON arrays) into a clean dictionary.
    #if canImport(FirebaseRemoteConfig)
    private func snapshotMergingFirebase(rc: RemoteConfig, ttl: TimeInterval, now: Date) -> RemoteConfigSnapshot {
        var dict = snapshot.values // start from existing snapshot so unspecified keys keep current values
        for (k, v) in rc.allKeys(from: .remote).map({ ($0, rc.configValue(forKey: $0)) }) {
            // Try to parse JSON first for list types, else fall back to typed primitives.
            if let data = v.dataValue, !data.isEmpty,
               let json = try? JSONSerialization.jsonObject(with: data) {
                dict[k] = json
                continue
            }
            if let s = v.stringValue, !s.isEmpty { dict[k] = s; continue }
            if let n = Double(v.numberValue ?? 0) as Double? {
                // Heuristic: ints are common; if integral, store as Int to ease decoding.
                if floor(n) == n { dict[k] = Int(n) } else { dict[k] = n }
                continue
            }
            dict[k] = v.boolValue
        }
        return RemoteConfigSnapshot(values: dict, fetchedAt: now, ttlSeconds: ttl)
    }
    #endif

    // Disk cache (JSON)
    private static func saveDiskCache(_ snap: RemoteConfigSnapshot, to url: URL) {
        let payload: [String: Any] = [
            "_meta": ["fetchedAt": snap.fetchedAt.timeIntervalSince1970, "ttl": snap.ttlSeconds],
            "values": snap.values
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func loadDiskCache(from url: URL) -> RemoteConfigSnapshot? {
        guard let d = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let meta = obj["_meta"] as? [String: Any],
              let ts = meta["fetchedAt"] as? TimeInterval,
              let ttl = meta["ttl"] as? TimeInterval,
              let vals = obj["values"] as? [String: Any] else { return nil }
        return RemoteConfigSnapshot(values: vals, fetchedAt: Date(timeIntervalSince1970: ts), ttlSeconds: ttl)
    }

    // Bundled defaults (Resources/RemoteConfigDefaults.json)
    private static func loadBundledJSON(named name: String, now: Date = Date(), ttl: TimeInterval = 6*3600) -> RemoteConfigSnapshot? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let d = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return RemoteConfigSnapshot(values: obj, fetchedAt: now, ttlSeconds: ttl)
    }

    private static func defaultSnapshot(ttl: TimeInterval) -> RemoteConfigSnapshot {
        RemoteConfigSnapshot(values: [
            RCKeys.profileCloudSyncEnabled.raw: RCKeys.profileCloudSyncEnabled.defaultValue,
            RCKeys.paywallMaxInterstitialsPer3Sessions.raw: RCKeys.paywallMaxInterstitialsPer3Sessions.defaultValue,
            RCKeys.paywallColdStartGateAfterFirstRide.raw: RCKeys.paywallColdStartGateAfterFirstRide.defaultValue,
            RCKeys.paywallSuppressAfterFailedPurchase.raw: RCKeys.paywallSuppressAfterFailedPurchase.defaultValue,
            RCKeys.editorExportPresets.raw: RCKeys.editorExportPresets.defaultValue,
            RCKeys.hazardGeofenceRadiusMeters.raw: RCKeys.hazardGeofenceRadiusMeters.defaultValue,
            RCKeys.speechCadenceThrottleSec.raw: RCKeys.speechCadenceThrottleSec.defaultValue,
            RCKeys.offlineCorridorBufferMeters.raw: RCKeys.offlineCorridorBufferMeters.defaultValue,
            RCKeys.referralsDailyAwardCap.raw: RCKeys.referralsDailyAwardCap.defaultValue
        ], fetchedAt: Date(), ttlSeconds: ttl)
    }

    private static let udkProfileOptIn = "rc.profile.optin"
}

// MARK: - DEBUG Fakes for tests

#if DEBUG
public final class RemoteConfigServiceFake: RemoteConfigServing {
    public var isProfileCloudSyncEnabled: Bool
    public var isProfileCloudOptIn: Bool
    public init(enabled: Bool = false, optIn: Bool = false) {
        self.isProfileCloudSyncEnabled = enabled
        self.isProfileCloudOptIn = optIn
    }
}
#endif

// MARK: - Test plan (unit/E2E summary)
//
// • Cache TTL: Instantiate with TTL=1s and a seeded disk snapshot. Assert refreshIfStale() no-ops <1s,
//   then fetches/loads after >1s. Stub Firebase (if linked) by toggling Config.firebaseEnabled and verify path.
//
// • Stale fallback: Simulate Firebase failure -> ensure bundle JSON loads and snapshot.fetchedAt updates,
//   then verify values come from bundle for keys present and defaults for others.
//
// • Type-safe decoding: Seed snapshot.values with mixed types (Int, Double, Bool, [String], String) and assert
//   value(RCKey<T>) returns correct T. Include commas string for array fallback ("a,b , c").
//
// • Local opt-in isolation: setProfileCloudOptIn(true) → isProfileCloudOptIn == true while
//   isProfileCloudSyncEnabled still tracks remote key; no network calls.
//
// • Backward compatibility: Missing bundle file → defaultSnapshot is used; service remains .ready.
//
// Integration wiring (AppDI):
//   let rc = RemoteConfigService(config: .init(cacheTTLSeconds: 21_600, bundledJSONName: "RemoteConfigDefaults", firebaseEnabled: true))
//   container.register(RemoteConfigService.self) { rc }
//   container.register(RemoteConfigServing.self) { rc } // to satisfy narrower protocol users
//
// Bundle file format (Resources/RemoteConfigDefaults.json) example:
// {
//   "paywall.max_interstitials_per_3_sessions": 1,
//   "paywall.cold_start_after_first_ride": true,
//   "editor.export_presets": ["feed_720p_30","story_1080x1920_30","archive_1080p_60"],
//   "hazard.geofence_radius_m": 120,
//   "offline.corridor_buffer_m": 150
// }
