// Services/Analytics/AnalyticsLogging+Store.swift
// Typed analytics helpers for StoreKit flows.
// Centralizes paywall commerce event names & params to avoid drift.

import Foundation

public extension AnalyticsLogging {
    func logPaywallCatalog(event: AnalyticsEvent.PaywallCatalogEvent) {
        log(event.analyticsEvent)
    }

    func logPaywallPurchase(event: AnalyticsEvent.PaywallPurchaseEvent) {
        log(event.analyticsEvent)
    }

    func logPaywallRestore(event: AnalyticsEvent.PaywallRestoreEvent) {
        log(event.analyticsEvent)
    }

    func logPaywallSubscription(event: AnalyticsEvent.PaywallSubscriptionEvent) {
        log(event.analyticsEvent)
    }

    func logPaywallOfferCode(event: AnalyticsEvent.PaywallOfferCodeEvent) {
        log(event.analyticsEvent)
    }
}

public extension AnalyticsEvent {
    enum PaywallCatalogEvent: Sendable {
        case loadStarted
        case loadSucceeded(productCount: Int)
        case loadRecoveredFromCache(productCount: Int)
        case loadFailed(errorCode: String?)
    }

    enum PaywallPurchaseEvent: Sendable {
        case started(productID: String)
        case succeeded(productID: String)
        case cancelled(productID: String)
        case pending(productID: String)
        case failed(productID: String, errorCode: String?)
        case consumableDelivered(productID: String)
        case revoked(productID: String)
    }

    enum PaywallRestoreEvent: Sendable {
        case started
        case succeeded(restoredCount: Int)
        case failed(errorCode: String?)
    }

    enum PaywallSubscriptionEvent: Sendable {
        case inactive(productID: String)
    }

    enum PaywallOfferCodeEvent: Sendable {
        case redemptionSheetShown
    }
}

private extension AnalyticsEvent.PaywallCatalogEvent {
    var analyticsEvent: AnalyticsEvent {
        switch self {
        case .loadStarted:
            return AnalyticsEvent(name: "paywall_catalog_load_started", category: .paywall)
        case .loadSucceeded(let productCount):
            return AnalyticsEvent(name: "paywall_catalog_load_succeeded",
                                  category: .paywall,
                                  params: ["count": .int(productCount)])
        case .loadRecoveredFromCache(let productCount):
            return AnalyticsEvent(name: "paywall_catalog_load_recovered_from_cache",
                                  category: .paywall,
                                  params: ["count": .int(productCount)])
        case .loadFailed(let errorCode):
            var params: [String: AnalyticsValue] = [:]
            if let errorCode {
                params["error_code"] = .string(errorCode)
            }
            return AnalyticsEvent(name: "paywall_catalog_load_failed", category: .paywall, params: params)
        }
    }
}

private extension AnalyticsEvent.PaywallPurchaseEvent {
    var analyticsEvent: AnalyticsEvent {
        switch self {
        case .started(let productID):
            return AnalyticsEvent(name: "paywall_purchase_started",
                                  category: .paywall,
                                  params: ["product_id": .string(productID)])
        case .succeeded(let productID):
            return AnalyticsEvent(name: "paywall_purchase_succeeded",
                                  category: .paywall,
                                  params: ["product_id": .string(productID)])
        case .cancelled(let productID):
            return AnalyticsEvent(name: "paywall_purchase_cancelled",
                                  category: .paywall,
                                  params: ["product_id": .string(productID)])
        case .pending(let productID):
            return AnalyticsEvent(name: "paywall_purchase_pending",
                                  category: .paywall,
                                  params: ["product_id": .string(productID)])
        case .failed(let productID, let errorCode):
            var params: [String: AnalyticsValue] = ["product_id": .string(productID)]
            if let errorCode {
                params["error_code"] = .string(errorCode)
            }
            return AnalyticsEvent(name: "paywall_purchase_failed", category: .paywall, params: params)
        case .consumableDelivered(let productID):
            return AnalyticsEvent(name: "paywall_consumable_delivered",
                                  category: .paywall,
                                  params: ["product_id": .string(productID)])
        case .revoked(let productID):
            return AnalyticsEvent(name: "paywall_purchase_revoked",
                                  category: .paywall,
                                  params: ["product_id": .string(productID)])
        }
    }
}

private extension AnalyticsEvent.PaywallRestoreEvent {
    var analyticsEvent: AnalyticsEvent {
        switch self {
        case .started:
            return AnalyticsEvent(name: "paywall_restore_started", category: .paywall)
        case .succeeded(let restoredCount):
            return AnalyticsEvent(name: "paywall_restore_succeeded",
                                  category: .paywall,
                                  params: ["count": .int(restoredCount)])
        case .failed(let errorCode):
            var params: [String: AnalyticsValue] = [:]
            if let errorCode {
                params["error_code"] = .string(errorCode)
            }
            return AnalyticsEvent(name: "paywall_restore_failed", category: .paywall, params: params)
        }
    }
}

private extension AnalyticsEvent.PaywallSubscriptionEvent {
    var analyticsEvent: AnalyticsEvent {
        switch self {
        case .inactive(let productID):
            return AnalyticsEvent(name: "paywall_subscription_inactive",
                                  category: .paywall,
                                  params: ["product_id": .string(productID)])
        }
    }
}

private extension AnalyticsEvent.PaywallOfferCodeEvent {
    var analyticsEvent: AnalyticsEvent {
        switch self {
        case .redemptionSheetShown:
            return AnalyticsEvent(name: "paywall_offer_code_redemption_shown", category: .paywall)
        }
    }
}
