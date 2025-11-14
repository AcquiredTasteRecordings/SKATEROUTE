// Services/Analytics/AnalyticsLogging+Store.swift
// StoreKit commerce/paywall analytics helpers.
// Provides typed sugar for Store to log structured events with minimal duplication.

import Foundation

public extension AnalyticsEvent {
    static var paywallCatalogLoadStarted: AnalyticsEvent {
        .init(name: "paywall_catalog_load_started", category: .paywall)
    }

    static var paywallCatalogLoadSucceeded: AnalyticsEvent {
        .init(name: "paywall_catalog_load_succeeded", category: .paywall)
    }

    static var paywallCatalogLoadRecoveredFromCache: AnalyticsEvent {
        .init(name: "paywall_catalog_load_recovered_from_cache", category: .paywall)
    }

    static func paywallCatalogLoadFailed(error: Error?) -> AnalyticsEvent {
        .init(name: "paywall_catalog_load_failed",
              category: .paywall,
              params: storeParams(error: error))
    }

    static func purchaseStarted(product: String) -> AnalyticsEvent {
        .init(name: "purchase_started",
              category: .commerce,
              params: storeParams(product: product))
    }

    static func consumableDelivered(product: String) -> AnalyticsEvent {
        .init(name: "consumable_delivered",
              category: .commerce,
              params: storeParams(product: product))
    }

    static func purchaseSucceeded(product: String) -> AnalyticsEvent {
        .init(name: "purchase_succeeded",
              category: .commerce,
              params: storeParams(product: product))
    }

    static func purchaseCancelled(product: String) -> AnalyticsEvent {
        .init(name: "purchase_cancelled",
              category: .commerce,
              params: storeParams(product: product))
    }

    static func purchasePending(product: String) -> AnalyticsEvent {
        .init(name: "purchase_pending",
              category: .commerce,
              params: storeParams(product: product))
    }

    static func purchaseFailed(product: String, error: Error? = nil) -> AnalyticsEvent {
        .init(name: "purchase_failed",
              category: .commerce,
              params: storeParams(product: product, error: error))
    }

    static var restoreStarted: AnalyticsEvent {
        .init(name: "restore_started", category: .commerce)
    }

    static func restoreSucceeded(count: Int) -> AnalyticsEvent {
        .init(name: "restore_succeeded",
              category: .commerce,
              params: ["count": .int(count)])
    }

    static func restoreFailed(error: Error? = nil) -> AnalyticsEvent {
        .init(name: "restore_failed",
              category: .commerce,
              params: storeParams(error: error))
    }

    static var offerCodeRedemptionShown: AnalyticsEvent {
        .init(name: "offer_code_redemption_shown", category: .paywall)
    }

    static func purchaseRevoked(product: String) -> AnalyticsEvent {
        .init(name: "purchase_revoked",
              category: .commerce,
              params: storeParams(product: product))
    }

    static func subscriptionInactive(product: String) -> AnalyticsEvent {
        .init(name: "subscription_inactive",
              category: .commerce,
              params: storeParams(product: product))
    }
}

public extension AnalyticsLogging {
    func logPaywallCatalogLoadStarted() {
        log(.paywallCatalogLoadStarted)
    }

    func logPaywallCatalogLoadSucceeded() {
        log(.paywallCatalogLoadSucceeded)
    }

    func logPaywallCatalogLoadRecoveredFromCache() {
        log(.paywallCatalogLoadRecoveredFromCache)
    }

    func logPaywallCatalogLoadFailed(_ error: Error?) {
        log(.paywallCatalogLoadFailed(error: error))
    }

    func logPurchaseStarted(product: String) {
        log(.purchaseStarted(product: product))
    }

    func logConsumableDelivered(product: String) {
        log(.consumableDelivered(product: product))
    }

    func logPurchaseSucceeded(product: String) {
        log(.purchaseSucceeded(product: product))
    }

    func logPurchaseCancelled(product: String) {
        log(.purchaseCancelled(product: product))
    }

    func logPurchasePending(product: String) {
        log(.purchasePending(product: product))
    }

    func logPurchaseFailed(product: String, error: Error? = nil) {
        log(.purchaseFailed(product: product, error: error))
    }

    func logRestoreStarted() {
        log(.restoreStarted)
    }

    func logRestoreSucceeded(count: Int) {
        log(.restoreSucceeded(count: count))
    }

    func logRestoreFailed(error: Error? = nil) {
        log(.restoreFailed(error: error))
    }

    func logOfferCodeRedemptionShown() {
        log(.offerCodeRedemptionShown)
    }

    func logPurchaseRevoked(product: String) {
        log(.purchaseRevoked(product: product))
    }

    func logSubscriptionInactive(product: String) {
        log(.subscriptionInactive(product: product))
    }
}

private func storeParams(product: String? = nil, error: Error? = nil) -> [String: AnalyticsValue] {
    var params: [String: AnalyticsValue] = [:]
    if let product {
        params["product_id"] = .string(product)
    }
    if let error {
        let nsError = error as NSError
        params["error_domain"] = .string(nsError.domain)
        params["error_code"] = .int(nsError.code)
    }
    return params
}
