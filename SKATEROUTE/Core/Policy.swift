// Core/Policy.swift
// Immutable privacy + safety policy for SkateRoute.
// Centralizes everything we must *not* do (tracking/ads) and what we *will* do (safety,
// ethical growth, content rules). Pure constants + a few tiny helpers used across the app.
//
// This file intentionally contains NO runtime switches fetched from the network.
// If policy ever changes, we ship a new app version (immutable = predictable).

import Foundation
import CoreLocation

public enum Policy {

    // MARK: - Tracking & Ads

    public enum Tracking {
        /// We do not use cross-app tracking (no device fingerprinting, no ad IDs).
        public static let allowsCrossAppTracking = false

        /// We do not ask for AppTrackingTransparency authorization.
        /// Use in code paths where ATT would normally be requested.
        public static func shouldRequestATT() -> Bool { false }

        /// NSPrivacyTracking in the privacy manifest must remain false.
        /// Build/CI scripts may assert against this value.
        public static let privacyManifestTrackingFlag = false
    }

    public enum Ads {
        /// No third-party ad SDKs. Partner promotions are first-party content only.
        public static let allowsThirdPartyAds = false
        /// Any internal promotion surfaces must be clearly labeled.
        public static let requirePromoDisclosure = true
        /// If we ever A/B paywalls, restrict to copy/ordering—never deceptive timers or fake scarcity.
        public static let banDarkPatterns = true
    }

    // MARK: - Analytics & Diagnostics

    public enum Analytics {
        /// Permitted providers. Keep this small; OSLog is always allowed.
        public enum Provider: String, CaseIterable {
            case oslog       // Local device log + signposts (exportable with user consent)
            case firebaseLite // Optional, event-only with no ads + no IDFA (if enabled in build)
        }
        /// Providers compiled into this build. LiveAppDI chooses from this set.
        public static let allowedProviders: [Provider] = [.oslog, .firebaseLite]

        /// We never collect precise location as analytics payload; we only export on-device aggregates.
        public static let prohibitPreciseLocationInAnalytics = true

        /// We never collect personally identifiable content in analytics.
        public static let prohibitPIIInAnalytics = true
    }

    // MARK: - Data Retention & Export

    public enum DataRetention {
        /// Default retention for raw ride logs on device (days). Users can purge anytime.
        public static let rideLogsDays: Int = 30
        /// Hazard reports that are unconfirmed auto-expire after (days).
        public static let unconfirmedHazardTTLDays: Int = 14
        /// Local caches (tiles, offline routes) may be cleaned after (days) of inactivity.
        public static let offlineCacheSuggestedTTLDays: Int = 60
        /// Exports must be user-initiated (no background uploads of private data).
        public static let requireExplicitExportAction = true
    }

    // MARK: - User-Generated Content (UGC)

    public enum UGC {
        /// Words/phrases we will block at submission time (quick client heuristic;
        /// server-side lists can be stricter).
        public static let bannedTerms: [String] = [
            // Keep this list short on-device; enforce stricter server-side.
            "hate", "slur1", "slur2" // placeholders – replace with a curated, localized list
        ]

        /// Max video length for uploads (seconds) to keep moderation feasible on free tier.
        public static let maxUploadVideoSeconds: Int = 90

        /// Images and videos must be recorded or explicitly picked by the user (no silent background capture).
        public static let requireExplicitMediaChoice = true

        /// Content must respect public space rules; do not encourage trespassing or vandalism.
        public static let disallowTrespassContent = true

        /// If content is flagged by multiple trusted users, hide pending review.
        public static let hideOnMultiFlag = true
        public static let hideOnMultiFlagThreshold = 2
    }

    // MARK: - Safety (location sharing, hazards)

    public enum Safety {
        /// When sharing ride/spot externally, fuzz coordinates by default to protect privacy (meters).
        public static let shareLocationFuzzMeters: Double = 35
        /// Minimum age to create a public profile (client-side guard; server must enforce as well).
        public static let minimumPublicProfileAgeYears: Int = 13
        /// VoiceOver and Dynamic Type are first-class; reject “essential UI” without labels.
        public static let requireAccessibilityLabels = true
    }

    // MARK: - Growth & Paywall Ethics

    public enum Growth {
        /// Referral rewards are soft (stickers/badges/partner coupons), not cash.
        public static let allowCashRewards = false
        /// Paywall rules: show clear value, single price, restore button visible, no timers.
        public static let enforceEthicalPaywall = true
        /// Free tier capabilities (summarized here; detailed logic in Entitlements).
        public static let freeTierOfflineQuota = 2
    }

    // MARK: - Partnerships & Promotions

    public enum Partnerships {
        /// Promotional partners must be local businesses or municipal programs aligned with skating.
        public static let allowedPartnerCategories = ["Skate Shop", "Cafe", "Community Center", "City Parks"]
        /// Require explicit partner disclosure in UI.
        public static let requireDisclosureBadge = true
    }

    // MARK: - Small helper utilities (pure, deterministic)

    /// Redact obvious PII keys from a dictionary before logging/sharing.
    /// Prefer the Support/Feedback/Redactor for full-stack redaction; this is a minimal fallback.
    public static func redactPII(_ map: [String: Any]) -> [String: Any] {
        let piiKeys = Set(["email", "phone", "token", "apnsToken", "idfa", "idfv", "userId", "name"])
        var out: [String: Any] = [:]
        for (k, v) in map {
            if piiKeys.contains(k.lowercased()) {
                out[k] = "[REDACTED]"
            } else {
                out[k] = v
            }
        }
        return out
    }

    /// Deterministic coordinate fuzzing used for share links/screenshots.
    /// Uses a stable salt to keep the offset consistent within a short window while preventing reversal.
    public static func fuzzedCoordinate(_ c: CLLocationCoordinate2D,
                                        meters: Double = Safety.shareLocationFuzzMeters,
                                        salt: String = "skateroute.fuzz.v1") -> CLLocationCoordinate2D {
        guard meters > 0 else { return c }
        // Simple, deterministic pseudo-random offset using a hash of (lat,lon,salt).
        let key = "\(c.latitude),\(c.longitude),\(salt)"
        let h = UInt64(abs(key.hashValue))
        // Map two 0…1 values from hash
        let u1 = Double(h & 0xFFFF) / Double(0xFFFF)
        let u2 = Double((h >> 16) & 0xFFFF) / Double(0xFFFF)
        // Random polar offset with mean ~meters/2 (keeps nearby), cap at meters
        let radius = min(meters, (u1 * meters))
        let angle = u2 * 2 * Double.pi
        // Approx meters per degree
        let metersPerDegLat = 111_000.0
        let metersPerDegLon = metersPerDegLat * cos(c.latitude * .pi / 180)
        let dLat = (radius * sin(angle)) / metersPerDegLat
        let dLon = (radius * cos(angle)) / metersPerDegLon
        return CLLocationCoordinate2D(latitude: c.latitude + dLat, longitude: c.longitude + dLon)
    }

    /// Quick client-side heuristic to reject obviously disallowed content text.
    public static func isContentAllowed(text: String) -> Bool {
        let lowered = text.lowercased()
        for banned in UGC.bannedTerms {
            if lowered.contains(banned.lowercased()) { return false }
        }
        return true
    }

    /// Human-readable reasons to surface in UI when gating an action by policy.
    public enum Reason {
        public static let trackingDisabled = NSLocalizedString(
            "Cross-app tracking is disabled for privacy.", comment: "policy reason"
        )
        public static let adsDisabled = NSLocalizedString(
            "Third-party ads are not supported.", comment: "policy reason"
        )
        public static let contentRejected = NSLocalizedString(
            "Content violates community rules.", comment: "policy reason"
        )
        public static let ageRestricted = NSLocalizedString(
            "Feature unavailable due to age restrictions.", comment: "policy reason"
        )
    }
}

// MARK: - Lightweight compile-time assertions (DEBUG)

#if DEBUG
import os.log

public enum PolicyAsserts {
    /// Call once on launch (Debug) to loudly warn if someone added disallowed providers.
    public static func validateConfiguration() {
        // Guardrails for tracking/ads posture.
        assert(Policy.Tracking.allowsCrossAppTracking == false, "Policy violation: cross-app tracking must remain disabled.")
        assert(Policy.Ads.allowsThirdPartyAds == false, "Policy violation: third-party ad SDKs are not allowed.")
    }
}
#endif


