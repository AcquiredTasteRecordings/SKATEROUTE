// Services/StoreKit/StoreAnalyticsEvents.swift
// Typed analytics helpers for StoreKit flows.

import Foundation

public extension AnalyticsEvent {
    // Catalog lifecycle
    static var paywallCatalogLoadStarted: AnalyticsEvent {
        .init(name: "paywall_catalog_load_started", category: .commerce)
    }

    static var paywallCatalogLoadSucceeded: AnalyticsEvent {
        .init(name: "paywall_catalog_load_succeeded", category: .commerce)
    }

    static var paywallCatalogLoadRecoveredFromCache: AnalyticsEvent {
        .init(name: "paywall_catalog_load_recovered_from_cache", category: .commerce)
    }

    static var paywallCatalogLoadFailed: AnalyticsEvent {
        .init(name: "paywall_catalog_load_failed", category: .commerce)
    }

    // Purchase lifecycle
    static func purchaseStarted(product: String) -> AnalyticsEvent {
        .init(name: "purchase_started", category: .commerce, params: ["product": .string(product)])
    }

    static func purchaseSucceeded(product: String) -> AnalyticsEvent {
        .init(name: "purchase_succeeded", category: .commerce, params: ["product": .string(product)])
    }

    static func purchaseCancelled(product: String) -> AnalyticsEvent {
        .init(name: "purchase_cancelled", category: .commerce, params: ["product": .string(product)])
    }

    static func purchasePending(product: String) -> AnalyticsEvent {
        .init(name: "purchase_pending", category: .commerce, params: ["product": .string(product)])
    }

    static func purchaseFailed(product: String) -> AnalyticsEvent {
        .init(name: "purchase_failed", category: .commerce, params: ["product": .string(product)])
    }

    static func consumableDelivered(product: String) -> AnalyticsEvent {
        .init(name: "consumable_delivered", category: .commerce, params: ["product": .string(product)])
    }

    static func purchaseRevoked(product: String) -> AnalyticsEvent {
        .init(name: "purchase_revoked", category: .commerce, params: ["product": .string(product)])
    }

    static func subscriptionInactive(product: String) -> AnalyticsEvent {
        .init(name: "subscription_inactive", category: .commerce, params: ["product": .string(product)])
    }

    // Restore / maintenance flows
    static var restoreStarted: AnalyticsEvent {
        .init(name: "restore_started", category: .commerce)
    }

    static func restoreSucceeded(count: Int) -> AnalyticsEvent {
        .init(name: "restore_succeeded", category: .commerce, params: ["count": .int(count)])
    }

    static var restoreFailed: AnalyticsEvent {
        .init(name: "restore_failed", category: .commerce)
    }

    static var offerCodeRedemptionShown: AnalyticsEvent {
        .init(name: "offer_code_redemption_shown", category: .commerce)
    }
}

