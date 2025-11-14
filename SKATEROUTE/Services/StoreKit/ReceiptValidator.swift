//  Services/StoreKit/ReceiptValidator.swift
//  SKATEROUTE
//
//  Central entitlement inspector for SkateRoute's IAP/subscriptions.
//  Uses StoreKit 2 currentEntitlements to determine premium status.
//  No secrets, no server crypto, offline-friendly with last-known cache.
//

import Foundation
import StoreKit
import Combine

public enum PremiumPlanKind: String, Codable, CaseIterable, Sendable {
    case none
    case subscriptionMonthly
    case subscriptionYearly
    case lifetime
}

public struct PremiumStatus: Codable, Sendable, Equatable {
    public let isPremiumActive: Bool
    public let activePlan: PremiumPlanKind
    public let activeProductID: String?
    public let expirationDate: Date?
    public let willAutoRenew: Bool
    public let lastChecked: Date

    public static let notPremium = PremiumStatus(
        isPremiumActive: false,
        activePlan: .none,
        activeProductID: nil,
        expirationDate: nil,
        willAutoRenew: false,
        lastChecked: .init()
    )
}

/// On-device receipt / entitlement validator.
///
/// Responsibilities:
/// - Query StoreKit 2 for current entitlements
/// - Filter + verify premium products
/// - Expose a minimal `PremiumStatus` model for UI and feature-gating
///
/// This is intentionally client-only. For high-risk use-cases you can add
/// a server-side verifier later without breaking the surface area.
@MainActor
public final class ReceiptValidator: ObservableObject {

    // MARK: - Public state

    @Published public private(set) var status: PremiumStatus = .notPremium

    /// Convenience shim for callers that only care about “premium or not”.
    public var isPremiumActive: Bool { status.isPremiumActive }

    // MARK: - Config

    /// Product identifiers considered “premium” for entitlement evaluation.
    /// Keep this in sync with App Store Connect and your Paywall wiring (`com.skateroute.app.pro.<plan>`).
    private let premiumProductIDs: Set<String>

    /// Provides the current set of StoreKit entitlements to evaluate.
    private let entitlementsProvider: @Sendable () async throws -> [EntitlementSnapshot]

    /// Where to persist last-known status (for offline UI).
    private let cacheKey: String
    private let userDefaults: UserDefaults

    // MARK: - Init

    public init(
        premiumProductIDs: Set<String> = [
            "com.skateroute.pro.monthly",
            "com.skateroute.pro.yearly",
            "com.skateroute.pro.lifetime"
        ],
        cacheKey: String = "premium.status.cache.v2",
        userDefaults: UserDefaults = .standard
    ) {
        self.premiumProductIDs = premiumProductIDs
        self.cacheKey = cacheKey
        self.userDefaults = userDefaults
        self.entitlementsProvider = entitlementsProvider

        // Load cached snapshot for instant UI, then refresh from StoreKit.
        if let cached = Self.loadCachedStatus(from: userDefaults, key: cacheKey) {
            self.status = cached
        }
        if autoRefreshOnInit {
            Task { await self.refreshEntitlements() }
        }
    }

    // MARK: - Public API

    /// Force a full entitlement refresh from StoreKit.
    /// Call after purchase/restore flows or from a "Refresh" debug action.
    public func refreshEntitlements() async {
        let now = Date()
        do {
            let entitlements = try await entitlementsProvider()

            var best: EntitlementSnapshot?
            for snapshot in entitlements {
                guard premiumProductIDs.contains(snapshot.productID) else { continue }
                guard !isExpiredOrRevoked(snapshot, at: now) else { continue }

                if let currentBest = best {
                    if isMoreRecent(snapshot, than: currentBest) {
                        best = snapshot
                    }
                } else {
                    best = snapshot
                }
            }

            let newStatus = Self.buildStatus(from: best, at: now)
            applyStatus(newStatus)
        } catch {
            // If StoreKit fails, keep last-known status; don’t nuke UI.
            let degraded = PremiumStatus(
                isPremiumActive: status.isPremiumActive,
                activePlan: status.activePlan,
                activeProductID: status.activeProductID,
                expirationDate: status.expirationDate,
                willAutoRenew: status.willAutoRenew,
                lastChecked: now
            )
            applyStatus(degraded)
        }
    }

    /// Trigger Apple’s “Restore Purchases” flow and refresh entitlements.
    /// Use this from your Settings/Paywall UI.
    public func restorePurchases() async throws {
        _ = try await AppStore.sync()
        await refreshEntitlements()
    }

    /// Check whether the user is eligible for an introductory offer for a given product.
    /// This is a best-effort client-side heuristic using current entitlements.
    public func isIntroOfferEligible(for product: Product) async -> Bool {
        guard let subscription = product.subscription else {
            return false // Non-subscription products don't have intro offers.
        }

        do {
            for await result in Transaction.currentEntitlements {
                guard case .verified(let transaction) = result else { continue }
                guard transaction.productID == product.id else { continue }
                // If they've had this specific product before, assume no intro.
                return false
            }
        } catch {
            // On error we default to false to avoid misrepresenting eligibility.
            return false
        }

        // User hasn't had this product yet. For family of products you can add
        // extra rules (e.g., any premium subscription invalidates intro).
        switch subscription.subscriptionPeriod.unit {
        case .month, .week:
            return true
        case .year:
            return true
        @unknown default:
            return false
        }
    }

    // MARK: - Private helpers

    private func applyStatus(_ newStatus: PremiumStatus) {
        status = newStatus
        Self.cache(status: newStatus, to: userDefaults, key: cacheKey)
    }

    private func isExpiredOrRevoked(_ snapshot: EntitlementSnapshot, at date: Date) -> Bool {
        if let revocation = snapshot.revocationDate, revocation <= date {
            return true
        }
        if let exp = snapshot.expirationDate, exp <= date {
            return true
        }
        return false
    }

    private func isMoreRecent(_ a: EntitlementSnapshot, than b: EntitlementSnapshot) -> Bool {
        let aDate = a.expirationDate ?? a.purchaseDate
        let bDate = b.expirationDate ?? b.purchaseDate
        return aDate > bDate
    }

    private static func buildStatus(from snapshot: EntitlementSnapshot?, at now: Date) -> PremiumStatus {
        guard let snapshot else {
            return .notPremium
        }

        let exp = snapshot.expirationDate
        let isLifetime = exp == nil

        let plan: PremiumPlanKind = {
            if isLifetime { return .lifetime }
            // Heuristic: map by duration; you can also map by productID if you want it explicit.
            if let unit = snapshot.subscriptionPeriodUnit {
                switch unit {
                case .month, .week: return .subscriptionMonthly
                case .year: return .subscriptionYearly
                @unknown default: return .subscriptionMonthly
                }
            }
            // Fallback: productID-based mapping
            if snapshot.productID.contains("lifetime") { return .lifetime }
            if snapshot.productID.contains("year") { return .subscriptionYearly }
            return .subscriptionMonthly
        }()

        let willAutoRenew: Bool = snapshot.revocationDate == nil && snapshot.isUpgraded == false

        return PremiumStatus(
            isPremiumActive: true,
            activePlan: plan,
            activeProductID: snapshot.productID,
            expirationDate: exp,
            willAutoRenew: willAutoRenew,
            lastChecked: now
        )
    }

    // MARK: - Caching

    private static func loadCachedStatus(from defaults: UserDefaults, key: String) -> PremiumStatus? {
        if let data = defaults.data(forKey: key) {
            do {
                let decoded = try JSONDecoder().decode(PremiumStatus.self, from: data)
                if let migrated = migrateStatusIfNeeded(decoded, defaults: defaults, key: key) {
                    return migrated
                }
                return decoded
            } catch {
                // Fall through to legacy migration.
            }
        }

        return migrateLegacyStatus(from: defaults, key: key)
    }

    private static func cache(status: PremiumStatus, to defaults: UserDefaults, key: String) {
        do {
            let data = try JSONEncoder().encode(status)
            defaults.set(data, forKey: key)
        } catch {
            // Don’t crash on cache failure.
        }
    }

    // MARK: - Legacy support

    public struct EntitlementSnapshot: Sendable, Equatable {
        public let productID: String
        public let purchaseDate: Date
        public let expirationDate: Date?
        public let revocationDate: Date?
        public let isUpgraded: Bool
        public let subscriptionPeriodUnit: Product.SubscriptionPeriod.Unit?

        init(transaction: Transaction) {
            self.productID = transaction.productID
            self.purchaseDate = transaction.purchaseDate
            self.expirationDate = transaction.expirationDate
            self.revocationDate = transaction.revocationDate
            self.isUpgraded = transaction.isUpgraded
            self.subscriptionPeriodUnit = transaction.subscription?.subscriptionPeriod?.unit
        }

        public init(
            productID: String,
            purchaseDate: Date,
            expirationDate: Date?,
            revocationDate: Date?,
            isUpgraded: Bool,
            subscriptionPeriodUnit: Product.SubscriptionPeriod.Unit?
        ) {
            self.productID = productID
            self.purchaseDate = purchaseDate
            self.expirationDate = expirationDate
            self.revocationDate = revocationDate
            self.isUpgraded = isUpgraded
            self.subscriptionPeriodUnit = subscriptionPeriodUnit
        }
    }

    private static func migrateStatusIfNeeded(
        _ status: PremiumStatus,
        defaults: UserDefaults,
        key: String
    ) -> PremiumStatus? {
        guard let productID = status.activeProductID else { return nil }
        guard let replacement = legacyProductIDMapping[productID] else { return nil }

        let migrated = PremiumStatus(
            isPremiumActive: status.isPremiumActive,
            activePlan: status.activePlan,
            activeProductID: replacement,
            expirationDate: status.expirationDate,
            willAutoRenew: status.willAutoRenew,
            lastChecked: status.lastChecked
        )
        cache(status: migrated, to: defaults, key: key)
        return migrated
    }

    private static func migrateLegacyStatus(from defaults: UserDefaults, key: String) -> PremiumStatus? {
        for (legacyID, replacement) in legacyProductIDMapping {
            let candidateKeys = [
                "\(key).\(legacyID)",
                "premium.status.\(legacyID)",
                "premium.status.cache.\(legacyID)"
            ]

            for legacyKey in candidateKeys {
                guard let data = defaults.data(forKey: legacyKey) else { continue }
                guard let decoded = try? JSONDecoder().decode(PremiumStatus.self, from: data) else { continue }

                let migrated = PremiumStatus(
                    isPremiumActive: decoded.isPremiumActive,
                    activePlan: decoded.activePlan,
                    activeProductID: decoded.activeProductID == legacyID ? replacement : decoded.activeProductID,
                    expirationDate: decoded.expirationDate,
                    willAutoRenew: decoded.willAutoRenew,
                    lastChecked: decoded.lastChecked
                )

                cache(status: migrated, to: defaults, key: key)
                defaults.removeObject(forKey: legacyKey)
                return migrated
            }
        }

        return nil
    }

    private static func makeDefaultEntitlementsProvider() -> @Sendable () async throws -> [EntitlementSnapshot] {
        {
            var snapshots: [EntitlementSnapshot] = []
            do {
                for try await result in Transaction.currentEntitlements {
                    guard case .verified(let transaction) = result else { continue }
                    snapshots.append(EntitlementSnapshot(transaction: transaction))
                }
                return snapshots
            } catch {
                throw error
            }
        }
    }

    private static let legacyProductIDMapping: [String: String] = [
        "skateroute.premium.monthly": "com.skateroute.pro.monthly",
        "skateroute.premium.yearly": "com.skateroute.pro.yearly",
        "skateroute.premium.lifetime": "com.skateroute.pro.lifetime"
    ]
}


