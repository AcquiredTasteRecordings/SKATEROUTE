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
    /// Keep this in sync with App Store Connect and your Paywall wiring.
    private let premiumProductIDs: Set<String>

    /// Where to persist last-known status (for offline UI).
    private let cacheKey: String
    private let userDefaults: UserDefaults

    // MARK: - Init

    public init(
        premiumProductIDs: Set<String> = [
            "skateroute.premium.monthly",
            "skateroute.premium.yearly",
            "skateroute.premium.lifetime"
        ],
        cacheKey: String = "premium.status.cache",
        userDefaults: UserDefaults = .standard
    ) {
        self.premiumProductIDs = premiumProductIDs
        self.cacheKey = cacheKey
        self.userDefaults = userDefaults

        // Load cached snapshot for instant UI, then refresh from StoreKit.
        if let cached = Self.loadCachedStatus(from: userDefaults, key: cacheKey) {
            self.status = cached
        }
        Task { await self.refreshEntitlements() }
    }

    // MARK: - Public API

    /// Force a full entitlement refresh from StoreKit.
    /// Call after purchase/restore flows or from a "Refresh" debug action.
    public func refreshEntitlements() async {
        let now = Date()
        do {
            var best: Transaction?
            for await result in Transaction.currentEntitlements {
                guard case .verified(let transaction) = result else { continue }
                guard premiumProductIDs.contains(transaction.productID) else { continue }
                guard !isExpiredOrRevoked(transaction, at: now) else { continue }

                if let currentBest = best {
                    if isMoreRecent(transaction, than: currentBest) {
                        best = transaction
                    }
                } else {
                    best = transaction
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

    private func isExpiredOrRevoked(_ transaction: Transaction, at date: Date) -> Bool {
        if let revocation = transaction.revocationDate, revocation <= date {
            return true
        }
        if let exp = transaction.expirationDate, exp <= date {
            return true
        }
        return false
    }

    private func isMoreRecent(_ a: Transaction, than b: Transaction) -> Bool {
        let aDate = a.expirationDate ?? a.purchaseDate
        let bDate = b.expirationDate ?? b.purchaseDate
        return aDate > bDate
    }

    private static func buildStatus(from transaction: Transaction?, at now: Date) -> PremiumStatus {
        guard let tx = transaction else {
            return .notPremium
        }

        let exp = tx.expirationDate
        let isLifetime = exp == nil

        let plan: PremiumPlanKind = {
            if isLifetime { return .lifetime }
            // Heuristic: map by duration; you can also map by productID if you want it explicit.
            if let period = tx.subscription?.subscriptionPeriod {
                switch period.unit {
                case .month, .week: return .subscriptionMonthly
                case .year: return .subscriptionYearly
                @unknown default: return .subscriptionMonthly
                }
            }
            // Fallback: productID-based mapping
            if tx.productID.contains("lifetime") { return .lifetime }
            if tx.productID.contains("year") { return .subscriptionYearly }
            return .subscriptionMonthly
        }()

        let willAutoRenew: Bool = tx.revocationDate == nil && tx.isUpgraded == false

        return PremiumStatus(
            isPremiumActive: true,
            activePlan: plan,
            activeProductID: tx.productID,
            expirationDate: exp,
            willAutoRenew: willAutoRenew,
            lastChecked: now
        )
    }

    // MARK: - Caching

    private static func loadCachedStatus(from defaults: UserDefaults, key: String) -> PremiumStatus? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            let decoded = try JSONDecoder().decode(PremiumStatus.self, from: data)
            return decoded
        } catch {
            return nil
        }
    }

    private static func cache(status: PremiumStatus, to defaults: UserDefaults, key: String) {
        do {
            let data = try JSONEncoder().encode(status)
            defaults.set(data, forKey: key)
        } catch {
            // Don’t crash on cache failure.
        }
    }
}


