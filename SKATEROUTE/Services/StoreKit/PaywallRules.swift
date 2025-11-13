// Services/StoreKit/PaywallRules.swift
// Ethical, deterministic rules for when/how to show the paywall.
// No tracking. No dark patterns. On-device policy only.

import Foundation

// MARK: - PaywallRules

public struct PaywallRules {

    // MARK: Inputs

    /// Promotional window (typically hydrated from RemoteConfigService).
    public struct PromoWindow: Sendable, Equatable {
        public let startsAt: Date
        public let endsAt: Date
        public let eligibleRegions: Set<String>? // ISO region codes (e.g., "US", "CA"); nil = global
        public let gentleMode: Bool              // true => prefer banners over modals
        public init(startsAt: Date, endsAt: Date, eligibleRegions: Set<String>? = nil, gentleMode: Bool = false) {
            self.startsAt = startsAt; self.endsAt = endsAt; self.eligibleRegions = eligibleRegions; self.gentleMode = gentleMode
        }
        public func isActive(now: Date, region: String?) -> Bool {
            guard now >= startsAt && now <= endsAt else { return false }
            guard let eligible = eligibleRegions, let region else { return eligible.isEmpty }
            return eligible.contains(region)
        }
    }

    /// Context used for each decision.
    public struct Context: Sendable, Equatable {
        // Core inputs
        public var feature: ProFeature
        public var entitlements: Set<ProFeature>

        // Environment / user state
        public var isNetworkReachable: Bool
        public var isLowPowerModeEnabled: Bool
        public var isActivelyNavigating: Bool     // hard NO for modal while navigating
        public var hasCompletedFirstRoute: Bool   // cold start suppression until true
        public var hadFailedPurchaseLastSession: Bool

        // Time / session discipline
        public var now: Date = Date()
        public var lastShownAt: Date?
        public var lastShownForFeatureAt: Date?
        public var sessionsSinceLastInterstitial: Int? // frequency cap: need >= 3 to allow a new interstitial
        public var interstitialsShownThisSession: Int = 0

        // Quotas & local counters
        public var softQuotaRemaining: Int?
        public var priorDismissCountForFeature: Int = 0

        // Preferences / UX
        public var isCriticalUserFlow: Bool = false
        public var prefersNonModal: Bool = false

        // Locale / region
        public var locale: Locale = .current
        public var regionCode: String?            // ISO region (e.g., "US")

        // Remote-config driven promos
        public var promo: PromoWindow?

        public init(
            feature: ProFeature,
            entitlements: Set<ProFeature>,
            isNetworkReachable: Bool,
            isLowPowerModeEnabled: Bool,
            isActivelyNavigating: Bool,
            hasCompletedFirstRoute: Bool,
            hadFailedPurchaseLastSession: Bool,
            now: Date = Date(),
            lastShownAt: Date? = nil,
            lastShownForFeatureAt: Date? = nil,
            sessionsSinceLastInterstitial: Int? = nil,
            interstitialsShownThisSession: Int = 0,
            softQuotaRemaining: Int? = nil,
            priorDismissCountForFeature: Int = 0,
            isCriticalUserFlow: Bool = false,
            prefersNonModal: Bool = false,
            locale: Locale = .current,
            regionCode: String? = nil,
            promo: PromoWindow? = nil
        ) {
            self.feature = feature
            self.entitlements = entitlements
            self.isNetworkReachable = isNetworkReachable
            self.isLowPowerModeEnabled = isLowPowerModeEnabled
            self.isActivelyNavigating = isActivelyNavigating
            self.hasCompletedFirstRoute = hasCompletedFirstRoute
            self.hadFailedPurchaseLastSession = hadFailedPurchaseLastSession
            self.now = now
            self.lastShownAt = lastShownAt
            self.lastShownForFeatureAt = lastShownForFeatureAt
            self.sessionsSinceLastInterstitial = sessionsSinceLastInterstitial
            self.interstitialsShownThisSession = interstitialsShownThisSession
            self.softQuotaRemaining = softQuotaRemaining
            self.priorDismissCountForFeature = priorDismissCountForFeature
            self.isCriticalUserFlow = isCriticalUserFlow
            self.prefersNonModal = prefersNonModal
            self.locale = locale
            self.regionCode = regionCode
            self.promo = promo
        }
    }

    // MARK: Decision

    public enum Decision: Equatable, Sendable {
        case allow
        case suggestBanner(reason: Reason)
        case presentPaywall(reason: Reason, style: Style, cta: CTA)
        case block(reason: Reason)

        public enum Style: Sendable, Equatable { case inline, modalSheet, fullScreenCover }
        public enum CTA: Sendable, Equatable { case purchase, manage, restore }
        public enum Reason: Sendable, Equatable {
            case notEntitled(ProFeature)
            case softQuotaDepleted(ProFeature)
            case networkRequired
            case cooldownInEffect(until: Date)
            case coldStartDeferral
            case activeNavigation
            case sessionFrequencyCap
        }
    }

    // MARK: Policy knobs

    public struct Policy: Sendable, Equatable {
        public var globalCooldown: TimeInterval = 60 * 45               // 45m between modals
        public var perFeatureCooldown: TimeInterval = 60 * 30           // 30m per feature
        public var preferBannerWhenGentle = true
        public var maxBannerNudgesPerFeature = 2
        public var penaltyCooldownMultiplierPerDismiss: Double = 1.5
        public var disallowFullScreenInCritical = true
        public var neverWhileNavigating = true                           // hard ban on modal during live nav
        public var maxInterstitialsPerSession = 1                        // cap noise per session
        public var minSessionsBetweenInterstitials = 3                   // 1 interstitial per 3 sessions
        public var coreSafetyFeatures: Set<String> = ["hazard_alerts", "rerouting"]
        public var niceToHaveFeatureHints: Set<String> = ["offline_packs", "editor_export_hd", "premium_badges"]

        public init() {}
    }

    public let policy: Policy
    public init(policy: Policy = .init()) { self.policy = policy }

    // MARK: Public helpers (requested outputs)

    /// Boolean helper for simple gating.
    public func shouldPresentPaywall(context ctx: Context) -> Bool {
        switch evaluate(ctx) {
        case .presentPaywall: return true
        default: return false
        }
    }

    /// Placement helper for UI routing (inline banner, sheet, full-screen).
    public func placement(for decision: Decision) -> Decision.Style {
        switch decision {
        case .suggestBanner: return .inline
        case .presentPaywall(_, let style, _): return style
        default: return .inline
        }
    }

    // MARK: Evaluator

    public func evaluate(_ ctx: Context) -> Decision {
        // Already unlocked
        if ctx.entitlements.contains(ctx.feature) { return .allow }

        // Never block core safety features.
        if isCoreSafety(ctx.feature) { return .allow }

        // While actively navigating, never present a modal; banner at most.
        if policy.neverWhileNavigating && ctx.isActivelyNavigating {
            if let q = ctx.softQuotaRemaining, q > 0 { return .allow }
            return .suggestBanner(reason: .activeNavigation)
        }

        // Cold start: defer paywall until first completed route.
        if ctx.hasCompletedFirstRoute == false {
            // Allow action; optionally nudge.
            if wantsGentle(ctx) { return .suggestBanner(reason: .coldStartDeferral) }
            return .allow
        }

        // After a failed purchase in the last session, be polite: banner only / defer.
        if ctx.hadFailedPurchaseLastSession {
            if let q = ctx.softQuotaRemaining, q > 0 { return .allow }
            return .suggestBanner(reason: .notEntitled(ctx.feature))
        }

        // Soft quota path: if quota remains, allow; maybe suggest banner.
        if let q = ctx.softQuotaRemaining, q > 0 {
            return wantsGentle(ctx) ? .suggestBanner(reason: .notEntitled(ctx.feature)) : .allow
        }

        // Session frequency caps
        if ctx.interstitialsShownThisSession >= policy.maxInterstitialsPerSession {
            return .suggestBanner(reason: .sessionFrequencyCap)
        }
        if let since = ctx.sessionsSinceLastInterstitial, since < policy.minSessionsBetweenInterstitials {
            return .suggestBanner(reason: .sessionFrequencyCap)
        }

        // Global/per-feature cooldowns
        let now = ctx.now
        if let g = ctx.lastShownAt, now.timeIntervalSince(g) < policy.globalCooldown {
            return .suggestBanner(reason: .cooldownInEffect(until: g.addingTimeInterval(policy.globalCooldown)))
        }
        if let f = ctx.lastShownForFeatureAt {
            let penalty = pow(policy.penaltyCooldownMultiplierPerDismiss, Double(max(0, ctx.priorDismissCountForFeature)))
            let perFeatureCd = policy.perFeatureCooldown * penalty
            if now.timeIntervalSince(f) < perFeatureCd {
                return .suggestBanner(reason: .cooldownInEffect(until: f.addingTimeInterval(perFeatureCd)))
            }
        }

        // No network means we can't purchase/restore.
        if !ctx.isNetworkReachable { return .block(reason: .networkRequired) }

        // Promo window may force gentle mode.
        let promoGentle = (ctx.promo?.isActive(now: ctx.now, region: ctx.regionCode) ?? false) && (ctx.promo?.gentleMode ?? false)
        if wantsGentle(ctx) || promoGentle {
            // Respect banner cap per feature before escalating.
            if ctx.priorDismissCountForFeature < policy.maxBannerNudgesPerFeature {
                return .suggestBanner(reason: .softQuotaDepleted(ctx.feature))
            }
        }

        // Decide modal style
        let style: Decision.Style = (policy.disallowFullScreenInCritical && ctx.isCriticalUserFlow) ? .modalSheet : .modalSheet
        // CTA selection: default purchase; if app believes user is entitled but cache stale, use restore/manage.
        let cta: Decision.CTA = .purchase

        return .presentPaywall(reason: .softQuotaDepleted(ctx.feature), style: style, cta: cta)
    }

    // MARK: - Helpers

    private func wantsGentle(_ ctx: Context) -> Bool {
        if policy.preferBannerWhenGentle && (ctx.isLowPowerModeEnabled || ctx.prefersNonModal) { return true }
        if let promo = ctx.promo, promo.isActive(now: ctx.now, region: ctx.regionCode), promo.gentleMode { return true }
        return false
    }

    private func isCoreSafety(_ feature: ProFeature) -> Bool {
        policy.coreSafetyFeatures.contains(feature.rawValue)
    }

    /// Optional: use hints for nicer copy or gating strictness; not required for decisions.
    private func isNiceToHave(_ feature: ProFeature) -> Bool {
        policy.niceToHaveFeatureHints.contains(feature.rawValue)
    }
}

// MARK: - On-device counters (local only)

public struct PaywallCounters {
    private let defaults: UserDefaults

    private enum K {
        static let lastShownAt = "Paywall.lastShownAt"
        static func lastShownForFeature(_ f: ProFeature) -> String { "Paywall.lastShownFor.\(f.rawValue)" }
        static func dismissCount(_ f: ProFeature) -> String { "Paywall.dismissCount.\(f.rawValue)" }
        static func bannerNudges(_ f: ProFeature) -> String { "Paywall.bannerNudges.\(f.rawValue)" }
        static let firstInstallDate = "App.firstInstallDate"
        static let sessionOrdinal = "App.session.ordinal"
        static let lastInterstitialSession = "Paywall.lastInterstitialSession"
        static let interstitialsShownThisSession = "Paywall.interstitialsShownThisSession"
        static let lastPurchaseFailedSession = "Paywall.lastPurchaseFailedSession"
        static let hasCompletedFirstRoute = "Paywall.hasCompletedFirstRoute"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: K.firstInstallDate) == nil { defaults.set(Date(), forKey: K.firstInstallDate) }
        if defaults.object(forKey: K.sessionOrdinal) == nil { defaults.set(1, forKey: K.sessionOrdinal) }
        if defaults.object(forKey: K.interstitialsShownThisSession) == nil { defaults.set(0, forKey: K.interstitialsShownThisSession) }
    }

    // Session lifecycle hooks (call from AppCoordinator)
    public func beginNewSession() {
        let n = (defaults.integer(forKey: K.sessionOrdinal) + 1)
        defaults.set(n, forKey: K.sessionOrdinal)
        defaults.set(0, forKey: K.interstitialsShownThisSession)
    }

    public func markPurchaseFailedThisSession() {
        defaults.set(defaults.integer(forKey: K.sessionOrdinal), forKey: K.lastPurchaseFailedSession)
    }

    public func markCompletedFirstRoute() {
        defaults.set(true, forKey: K.hasCompletedFirstRoute)
    }

    // Counters

    public var lastShownAt: Date? {
        get { defaults.object(forKey: K.lastShownAt) as? Date }
        set { defaults.set(newValue, forKey: K.lastShownAt) }
    }

    public func lastShownForFeature(_ f: ProFeature) -> Date? {
        defaults.object(forKey: K.lastShownForFeature(f)) as? Date
    }

    public func setLastShownForFeature(_ f: ProFeature, date: Date = Date()) {
        defaults.set(date, forKey: K.lastShownForFeature(f))
        defaults.set(date, forKey: K.lastShownAt)
        // bookkeeping for session frequency
        defaults.set(currentSessionInterstitials + 1, forKey: K.interstitialsShownThisSession)
        defaults.set(sessionOrdinal, forKey: K.lastInterstitialSession)
    }

    public func incrementDismiss(for f: ProFeature) {
        let key = K.dismissCount(f)
        defaults.set(dismissCount(for: f) + 1, forKey: key)
    }

    public func dismissCount(for f: ProFeature) -> Int {
        defaults.integer(forKey: K.dismissCount(f))
    }

    public func incrementBannerNudge(for f: ProFeature) {
        let key = K.bannerNudges(f)
        defaults.set(bannerNudges(for: f) + 1, forKey: key)
    }

    public func bannerNudges(for f: ProFeature) -> Int {
        defaults.integer(forKey: K.bannerNudges(f))
    }

    public var isFirstWeekSinceInstall: Bool {
        guard let d = defaults.object(forKey: K.firstInstallDate) as? Date else { return true }
        return Date().timeIntervalSince(d) < (7 * 24 * 60 * 60)
    }

    public var sessionOrdinal: Int { defaults.integer(forKey: K.sessionOrdinal) }
    public var currentSessionInterstitials: Int { defaults.integer(forKey: K.interstitialsShownThisSession) }

    public var sessionsSinceLastInterstitial: Int? {
        let last = defaults.integer(forKey: K.lastInterstitialSession)
        guard last > 0 else { return nil }
        return max(0, sessionOrdinal - last)
    }

    public var hadFailedPurchaseLastSession: Bool {
        let failed = defaults.integer(forKey: K.lastPurchaseFailedSession)
        return failed > 0 && failed == (sessionOrdinal - 1)
    }

    public var hasCompletedFirstRoute: Bool {
        defaults.bool(forKey: K.hasCompletedFirstRoute)
    }

    public func resetFeature(_ f: ProFeature) {
        defaults.removeObject(forKey: K.lastShownForFeature(f))
        defaults.removeObject(forKey: K.dismissCount(f))
        defaults.removeObject(forKey: K.bannerNudges(f))
    }
}

// MARK: - Coordinator bridge

public enum PaywallCoordinatorBridge {
    /// Single entry to decide + update counters for a given feature access attempt.
    public static func decide(
        feature: ProFeature,
        entitlements: Set<ProFeature>,
        counters: PaywallCounters,
        networkReachable: Bool,
        lowPowerMode: Bool,
        prefersNonModal: Bool,
        isCritical: Bool,
        isActivelyNavigating: Bool,
        softQuotaRemaining: Int?,
        regionCode: String?,
        promo: PaywallRules.PromoWindow?
    ) -> PaywallRules.Decision {

        let rules = PaywallRules()

        let ctx = PaywallRules.Context(
            feature: feature,
            entitlements: entitlements,
            isNetworkReachable: networkReachable,
            isLowPowerModeEnabled: lowPowerMode,
            isActivelyNavigating: isActivelyNavigating,
            hasCompletedFirstRoute: counters.hasCompletedFirstRoute,
            hadFailedPurchaseLastSession: counters.hadFailedPurchaseLastSession,
            now: Date(),
            lastShownAt: counters.lastShownAt,
            lastShownForFeatureAt: counters.lastShownForFeature(feature),
            sessionsSinceLastInterstitial: counters.sessionsSinceLastInterstitial,
            interstitialsShownThisSession: counters.currentSessionInterstitials,
            softQuotaRemaining: softQuotaRemaining,
            priorDismissCountForFeature: counters.dismissCount(for: feature),
            isCriticalUserFlow: isCritical,
            prefersNonModal: prefersNonModal,
            locale: .current,
            regionCode: regionCode,
            promo: promo
        )

        let decision = rules.evaluate(ctx)

        // Update counters on outcomes
        switch decision {
        case .presentPaywall:
            counters.setLastShownForFeature(feature)
        case .suggestBanner:
            counters.incrementBannerNudge(for: feature)
        default:
            break
        }

        return decision
    }
}

// MARK: - Preview/Test shims

#if DEBUG
public struct PaywallRulesPreviewData {
    public static func makeContext(
        feature: ProFeature,
        entitled: Bool = false,
        quota: Int? = nil,
        navigating: Bool = false,
        completedFirstRoute: Bool = true,
        sessionsSinceInterstitial: Int? = 5,
        interstitialsThisSession: Int = 0,
        failedPurchaseLastSession: Bool = false,
        promo: PaywallRules.PromoWindow? = nil
    ) -> PaywallRules.Context {
        PaywallRules.Context(
            feature: feature,
            entitlements: entitled ? [feature] : [],
            isNetworkReachable: true,
            isLowPowerModeEnabled: false,
            isActivelyNavigating: navigating,
            hasCompletedFirstRoute: completedFirstRoute,
            hadFailedPurchaseLastSession: failedPurchaseLastSession,
            now: Date(),
            lastShownAt: nil,
            lastShownForFeatureAt: nil,
            sessionsSinceLastInterstitial: sessionsSinceInterstitial,
            interstitialsShownThisSession: interstitialsThisSession,
            softQuotaRemaining: quota,
            priorDismissCountForFeature: 0,
            isCriticalUserFlow: false,
            prefersNonModal: false,
            locale: .current,
            regionCode: Locale.current.regionCode,
            promo: promo
        )
    }
}
#endif


