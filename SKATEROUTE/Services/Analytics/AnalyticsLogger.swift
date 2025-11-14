// Services/Analytics/AnalyticsLogger.swift
// Centralized analytics without user tracking.
// • Primary sink: OSLog (unified logging) with focused categories: routing, elevation, recorder, overlay, privacy.
// • Optional façade to Firebase Analytics (OFF by default) guarded behind compile flags and a kill-switch.
// • Redaction by policy: only whitelisted keys flow to external analytics; everything else is dropped or scrubbed.
// • Deterministic sampling (0.0...1.0) via on-device anonymous seed; no PII, no ATT, no user identifiers.
// • Lightweight signpost helpers for performance spans.
//
// IMPORTANT: Never send user IDs, email, exact coordinates, or device fingerprints. Treat ALL unlisted params as sensitive.

import Foundation
import os.log

// MARK: - Firebase (optional; compiled only if the SDK is linked)
#if canImport(FirebaseAnalytics)
import FirebaseAnalytics
#endif

// MARK: - Public API (DI seam)

public protocol AnalyticsLogging: AnyObject {
    /// Fire-and-forget analytics event. Safe to call from any thread.
    func log(_ event: AnalyticsEvent)

    /// Update runtime config (enables/disable façade, change sampling, etc.)
    func updateConfig(_ config: AnalyticsLogger.Config)

    /// Signpost spans for perf analysis (writes to OSLog only).
    func beginSpan(_ span: AnalyticsSpan) -> AnalyticsSpanHandle
    func endSpan(_ handle: AnalyticsSpanHandle)
}

// MARK: - Event model

public struct AnalyticsEvent: Sendable, Hashable {
    public enum Category: String, Sendable {
        case routing, elevation, recorder, overlay, privacy, commerce, referrals, paywall, media, hazards
        case challenges, leaderboard, comments, favorites
    }

    /// Canonical snake_case name, e.g., "route_planned", "hazard_merged"
    public let name: String
    public let category: Category
    /// Flat, JSON-safe primitives. Only keys allowed by redaction policy will be forwarded to any external sink.
    public let params: [String: AnalyticsValue]
    /// If set, overrides default sampling for this event only (0...1 inclusive).
    public let sampleRateOverride: Double?

    public init(name: String,
                category: Category,
                params: [String: AnalyticsValue] = [:],
                sampleRateOverride: Double? = nil) {
        self.name = name
        self.category = category
        self.params = params
        self.sampleRateOverride = sampleRateOverride
    }
}

public enum AnalyticsValue: Sendable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

// MARK: - Spans (OS signposts)

public struct AnalyticsSpan: Sendable, Hashable {
    public enum Category: String { case routing, elevation, recorder, overlay, privacy, media }
    public let name: String
    public let category: Category
    public let metadata: String?
    public init(_ name: String, category: Category, metadata: String? = nil) {
        self.name = name; self.category = category; self.metadata = metadata
    }
}

public struct AnalyticsSpanHandle: Sendable, Hashable {
    fileprivate let id: UUID
    fileprivate let span: AnalyticsSpan
}

// MARK: - Logger

@MainActor
public final class AnalyticsLogger: AnalyticsLogging {

    // Runtime config (mutable)
    public struct Config: Equatable {
        /// Global kill switch for the external façade (OSLog always on).
        public var firebaseEnabled: Bool = false
        /// Default sample rate for events [0,1]. 1 = all events, 0.1 = 10%.
        public var defaultSampleRate: Double = 1.0
        /// Event-level overrides: "route_planned" → 0.25
        public var eventSampleRates: [String: Double] = [:]
        /// Whitelisted keys that are allowed to leave the device (Firebase). Others are dropped/redacted.
        public var allowedKeys: Set<String> = [
            // High-signal, safe, aggregate-friendly keys ONLY
            "reason", "mode", "variant", "grade_bucket", "duration_ms",
            "distance_m", "count", "result", "error_code", "status",
            "locale", "app_version", "sdk_version"
        ]
        /// Keys for which we always drop values completely (even for OSLog params).
        public var denyKeys: Set<String> = [
            // Defense-in-depth; these should never be sent to logEvent callers anyway
            "user_id", "email", "phone", "lat", "lon", "coordinate", "ip", "advertising_id"
        ]
        /// Max string length to keep for values (long strings get truncated with ellipsis)
        public var maxString: Int = 120

        public init() {}
    }

    // MARK: Public (DI entry)

    public func updateConfig(_ config: Config) { self.config = config }

    public func log(_ event: AnalyticsEvent) {
        guard shouldSample(event) else { return }

        // 1) Always log to OSLog (with redaction for deny-list keys only).
        logOS(event)

        // 2) Optionally forward to Firebase, with strict whitelist & redaction.
        #if canImport(FirebaseAnalytics)
        if config.firebaseEnabled {
            let params = sanitizeForExternal(event.params)
            Analytics.logEvent(event.name, parameters: params.isEmpty ? nil : params)
        }
        #endif
    }

    public func beginSpan(_ span: AnalyticsSpan) -> AnalyticsSpanHandle {
        let log = osLogger(for: span.category)
        let id = OSSignpostID(log: log)
        if let meta = span.metadata, !meta.isEmpty {
            os_signpost(.begin, log: log, name: span.name, signpostID: id, "%{public}s", truncate(meta, max: config.maxString))
        } else {
            os_signpost(.begin, log: log, name: span.name, signpostID: id)
        }
        let handle = AnalyticsSpanHandle(id: UUID(), span: span)
        spanMap[handle.id] = (log, id)
        return handle
    }

    public func endSpan(_ handle: AnalyticsSpanHandle) {
        guard let pair = spanMap.removeValue(forKey: handle.id) else { return }
        os_signpost(.end, log: pair.log, name: handle.span.name, signpostID: pair.signpost)
    }

    // MARK: Init

    public init(config: Config = .init()) {
        self.config = config
        self.installSeed = AnalyticsLogger.loadOrCreateSeed()
        // Attach app & SDK versions as default context into OSLog only (no global user properties to Firebase).
        #if canImport(FirebaseAnalytics)
        // DO NOT set any userId. App version can be added ad-hoc per event via params.
        #endif
    }

    // MARK: Internals

    private var config: Config
    private let installSeed: UInt64
    private var spanMap: [UUID: (log: OSLog, signpost: OSSignpostID)] = [:]

    // OSLog categories (stable)
    private let logRouting     = Logger(subsystem: "com.skateroute", category: "routing")
    private let logElevation   = Logger(subsystem: "com.skateroute", category: "elevation")
    private let logRecorder    = Logger(subsystem: "com.skateroute", category: "recorder")
    private let logOverlay     = Logger(subsystem: "com.skateroute", category: "overlay")
    private let logPrivacy     = Logger(subsystem: "com.skateroute", category: "privacy")
    private let logCommerce    = Logger(subsystem: "com.skateroute", category: "commerce")
    private let logReferrals   = Logger(subsystem: "com.skateroute", category: "referrals")
    private let logPaywall     = Logger(subsystem: "com.skateroute", category: "paywall")
    private let logMedia       = Logger(subsystem: "com.skateroute", category: "media")
    private let logHazards     = Logger(subsystem: "com.skateroute", category: "hazards")
    private let logChallenges  = Logger(subsystem: "com.skateroute", category: "challenges")
    private let logLeaderboard = Logger(subsystem: "com.skateroute", category: "leaderboard")
    private let logComments    = Logger(subsystem: "com.skateroute", category: "comments")
    private let logFavorites   = Logger(subsystem: "com.skateroute", category: "favorites")
    private let logErrors      = Logger(subsystem: "com.skateroute", category: "analytics.errors")

    private func osLogger(for cat: AnalyticsSpan.Category) -> OSLog {
        switch cat {
        case .routing:   return OSLog(subsystem: "com.skateroute", category: "routing")
        case .elevation: return OSLog(subsystem: "com.skateroute", category: "elevation")
        case .recorder:  return OSLog(subsystem: "com.skateroute", category: "recorder")
        case .overlay:   return OSLog(subsystem: "com.skateroute", category: "overlay")
        case .privacy:   return OSLog(subsystem: "com.skateroute", category: "privacy")
        case .media:     return OSLog(subsystem: "com.skateroute", category: "media")
        }
    }

    private func logOS(_ event: AnalyticsEvent) {
        let safe = sanitizeForOS(event.params)
        let kv = safe.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let line = "[\(event.name)] \(kv)"
        switch event.category {
        case .routing:     logRouting.log("\(line, privacy: .public)")
        case .elevation:   logElevation.log("\(line, privacy: .public)")
        case .recorder:    logRecorder.log("\(line, privacy: .public)")
        case .overlay:     logOverlay.log("\(line, privacy: .public)")
        case .privacy:     logPrivacy.log("\(line, privacy: .public)")
        case .commerce:    logCommerce.log("\(line, privacy: .public)")
        case .referrals:   logReferrals.log("\(line, privacy: .public)")
        case .paywall:     logPaywall.log("\(line, privacy: .public)")
        case .media:       logMedia.log("\(line, privacy: .public)")
        case .hazards:     logHazards.log("\(line, privacy: .public)")
        case .challenges:  logChallenges.log("\(line, privacy: .public)")
        case .leaderboard: logLeaderboard.log("\(line, privacy: .public)")
        case .comments:    logComments.log("\(line, privacy: .public)")
        case .favorites:   logFavorites.log("\(line, privacy: .public)")
        }
    }

    // MARK: Sampling

    private func shouldSample(_ event: AnalyticsEvent) -> Bool {
        let p = max(0.0, min(1.0, event.sampleRateOverride ?? config.eventSampleRates[event.name] ?? config.defaultSampleRate))
        guard p < 1.0 else { return true }
        // Deterministic hash(seed,eventName) ∈ [0,1)
        var hasher = Hasher()
        hasher.combine(installSeed)
        hasher.combine(event.name)
        let h = UInt64(bitPattern: Int64(hasher.finalize()))
        let value = Double(h % 10_000) / 10_000.0
        return value < p
    }

    private static func loadOrCreateSeed() -> UInt64 {
        let key = "analytics.install.seed"
        let d = UserDefaults.standard
        if let s = d.object(forKey: key) as? UInt64 { return s }
        var rnd: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &rnd) { SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }
        d.set(rnd, forKey: key)
        return rnd
    }

    // MARK: Redaction & sanitation

    /// Redaction for OSLog: drop deny-listed keys, bound string lengths, and stringify everything.
    private func sanitizeForOS(_ params: [String: AnalyticsValue]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in params {
            if config.denyKeys.contains(k) { continue }
            out[k] = truncate(stringify(v), max: config.maxString)
        }
        // Attach minimal context
        out["app_version"] = truncate(appVersion(), max: 32)
        out["locale"] = Locale.autoupdatingCurrent.identifier
        return out
    }

    /// Redaction for external sink: only whitelisted keys make it out.
    private func sanitizeForExternal(_ params: [String: AnalyticsValue]) -> [String: NSObject] {
        var out: [String: NSObject] = [:]
        for (k, v) in params where config.allowedKeys.contains(k) && !config.denyKeys.contains(k) {
            switch v {
            case .string(let s): out[k] = truncate(s, max: config.maxString) as NSString
            case .int(let i):    out[k] = NSNumber(value: i)
            case .double(let d): out[k] = NSNumber(value: d)
            case .bool(let b):   out[k] = NSNumber(value: b)
            }
        }
        // Add safe context
        out["app_version"] = appVersion() as NSString
        out["locale"] = Locale.autoupdatingCurrent.identifier as NSString
        #if canImport(FirebaseAnalytics)
        // Firebase disallows overly long names/values; we already bound them.
        #endif
        return out
    }

    private func stringify(_ v: AnalyticsValue) -> String {
        switch v {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        }
    }

    private func truncate(_ s: String, max: Int) -> String {
        guard s.count > max, max > 3 else { return s }
        let end = s.index(s.startIndex, offsetBy: max - 1)
        return String(s[..<end]) + "…"
    }

    private func appVersion() -> String {
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(ver)(\(build))"
    }
}

private let fallbackAnalyticsErrorLogger = Logger(subsystem: "com.skateroute", category: "analytics.errors.fallback")

fileprivate protocol AnalyticsErrorRecording {
    func recordAnalyticsError(event: AnalyticsEvent, error: Error, file: StaticString, line: UInt)
}

public extension AnalyticsLogging {
    func record(event: AnalyticsEvent,
                error: Error? = nil,
                file: StaticString = #fileID,
                line: UInt = #line) {
        log(event)
        guard let error else { return }

        if let recorder = self as? AnalyticsErrorRecording {
            recorder.recordAnalyticsError(event: event, error: error, file: file, line: line)
        } else {
            let fileName = String(describing: file)
            fallbackAnalyticsErrorLogger.error("[\(event.name)] \(error.localizedDescription, privacy: .public) file: \(fileName, privacy: .public):\(line)")
        }
    }
}

extension AnalyticsLogger: AnalyticsErrorRecording {
    func recordAnalyticsError(event: AnalyticsEvent, error: Error, file: StaticString, line: UInt) {
        let fileName = String(describing: file)
        logErrors.error("[\(event.name)] \(error.localizedDescription, privacy: .public) file: \(fileName, privacy: .public):\(line)")
    }
}

// MARK: - Convenience factories for common events (optional sugar)

public extension AnalyticsEvent {
    static func routePlanned(result: String, distanceM: Double, durationMs: Int, variant: String) -> AnalyticsEvent {
        .init(name: "route_planned",
              category: .routing,
              params: ["result": .string(result),
                       "distance_m": .double(distanceM),
                       "duration_ms": .int(durationMs),
                       "variant": .string(variant)])
    }
    static func paywallShown(reason: String) -> AnalyticsEvent {
        .init(name: "paywall_shown", category: .paywall, params: ["reason": .string(reason)], sampleRateOverride: 1.0)
    }
    static func hazardMerged(count: Int, gradeBucket: String) -> AnalyticsEvent {
        .init(name: "hazard_merged", category: .hazards, params: ["count": .int(count), "grade_bucket": .string(gradeBucket)])
    }
    static func recorderFailed(code: String) -> AnalyticsEvent {
        .init(name: "recorder_failed", category: .recorder, params: ["error_code": .string(code)], sampleRateOverride: 1.0)
    }
}

// MARK: - DEBUG fakes (for unit tests)

#if DEBUG
public final class AnalyticsLoggerSpy: AnalyticsLogging {
    public private(set) var events: [AnalyticsEvent] = []
    public private(set) var spans: [AnalyticsSpanHandle: AnalyticsSpan] = [:]
    public private(set) var errors: [(event: AnalyticsEvent, error: any Error, file: StaticString, line: UInt)] = []
    private var cfg: AnalyticsLogger.Config = .init()
    public init() {}
    public func updateConfig(_ config: AnalyticsLogger.Config) { cfg = config }
    public func log(_ event: AnalyticsEvent) { events.append(event) }
    public func beginSpan(_ span: AnalyticsSpan) -> AnalyticsSpanHandle {
        let h = AnalyticsSpanHandle(id: UUID(), span: span); spans[h] = span; return h
    }
    public func endSpan(_ handle: AnalyticsSpanHandle) { spans.removeValue(forKey: handle) }
}

extension AnalyticsLoggerSpy: AnalyticsErrorRecording {
    func recordAnalyticsError(event: AnalyticsEvent, error: Error, file: StaticString, line: UInt) {
        errors.append((event: event, error: error, file: file, line: line))
    }
}
#endif

// MARK: - Test plan (unit)
// 1) Redaction verified:
//    - Configure allowedKeys = ["result","count"]; denyKeys includes "email".
//    - Log event with params ["result": "ok", "email": "a@b", "just_noise": "x"].
//    - Assert Firebase façade (if compiled) only receives "result", not "email"/"just_noise" (use a stub to intercept).
//
// 2) Sampling threshold honored:
//    - Set defaultSampleRate = 0.0 and event override route_planned → 1.0; routePlanned fires, others do not.
//    - With deterministic seed (set UserDefaults analytics.install.seed to a fixed value), assert sampling pass/fail is repeatable.
//
// 3) No PII:
//    - Attempt to send lat/lon/email keys → dropped by denyKeys; OSLog does not include them; Firebase receives none.
//
// 4) Signposts:
//    - beginSpan(.init("reroute", category: .routing)) / endSpan(handle) produce begin/end signposts (verify in Instruments).
//
// 5) Category mapping:
//    - routePlanned logs to "routing" logger; recorderFailed logs to "recorder"; ensure no crashes when unknown params present.
//
// Integration:
// • AppDI: register a singleton `AnalyticsLogger` with `firebaseEnabled = false` by default. Plumb into
//   Store, PaywallRules, SpeechCueEngine, Hazard services, Capture/Upload pipelines, and RemoteConfigService.
// • CI guardrail: add a unit test ensuring `denyKeys` includes "user_id","email","lat","lon"; fail PR if altered.
// • Build settings: do not include FirebaseAnalytics in release if not used; if included, keep façade off by default via RemoteConfig/Info.plist flag.


