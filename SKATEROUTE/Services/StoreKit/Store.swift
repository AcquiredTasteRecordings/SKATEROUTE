// Services/StoreKit/Store.swift
// StoreKit 2 service: product lookup, purchase/restore, entitlement sync.
// Zero secrets, no tracking. Integrates with Core/Entitlements.swift and AnalyticsLogger.
// Deployment: iOS 16+ (StoreKit 2). Safe defaults, robust error mapping, unit-test seams.

import Foundation
import StoreKit
import Combine
import OSLog

@MainActor
public final class Store: ObservableObject {

    // MARK: - Types

    public struct Item: Identifiable, Equatable, Sendable, Codable {
        public let id: ProductID
        public let displayName: String
        public let description: String
        public let price: String
        public let currencyCode: String?
        public let localeIdentifier: String?
        public let isFamilyShareable: Bool
        // Not codable: runtime SK2 product. Filled after cache load if online.
        public var rawProduct: Product?
        public var kind: Product.ProductType

        public var isSubscription: Bool { kind == .autoRenewable }
        public init(id: ProductID,
                    displayName: String,
                    description: String,
                    price: String,
                    currencyCode: String?,
                    localeIdentifier: String?,
                    isFamilyShareable: Bool,
                    rawProduct: Product?,
                    kind: Product.ProductType) {
            self.id = id
            self.displayName = displayName
            self.description = description
            self.price = price
            self.currencyCode = currencyCode
            self.localeIdentifier = localeIdentifier
            self.isFamilyShareable = isFamilyShareable
            self.rawProduct = rawProduct
            self.kind = kind
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        case loading
        case ready
        case purchasing(ProductID)
        case restoring
        case failed(message: String)
    }

    // MARK: - Published

    @Published public private(set) var state: State = .idle
    @Published public private(set) var products: [Item] = []
    @Published public private(set) var purchased: Set<ProductID> = []

    @Published public private(set) var lastError: UXError?

    // MARK: - Streams

    private let entitlementsSubject = CurrentValueSubject<Set<ProductID>, Never>([])
    public var entitlementsPublisher: AnyPublisher<Set<ProductID>, Never> { entitlementsSubject.eraseToAnyPublisher() }

    // MARK: - Dependencies

    private let entitlements: Entitlements
    private let analytics: AnalyticsLogger?
    private let log = Logger(subsystem: "com.skateroute.app", category: "Store")

    // MARK: - Caching (catalog + entitlements)

    private let defaults: UserDefaults
    private static let purchasedCacheKey = "Store.PurchasedProductIDs.payload.v2" // JSON payload (ids + updatedAt)
    private static let catalogCacheURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("StoreCatalog", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("catalog.json")
    }()
    private static let entitlementTTL: TimeInterval = 60 * 60 * 24 // 24h
    private static let catalogTTL: TimeInterval = 60 * 60 * 12    // 12h

    // MARK: - Tasks

    private var purchaseTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    private var subsStatusTask: Task<Void, Never>?

    // MARK: - Init

    public init(entitlements: Entitlements,
                analytics: AnalyticsLogger? = nil,
                defaults: UserDefaults = .standard) {
        self.entitlements = entitlements
        self.analytics = analytics
        self.defaults = defaults

        // Wire Entitlements callbacks.
        entitlements.validateReceipt = { [weak self] in
            guard let self else { return [] }
            return try await self.validProductsFromTransactions()
        }
        entitlements.performRestorePurchases = { [weak self] in
            guard let self else { return [] }
            return try await self.restorePurchases()
        }

        // Warm purchase cache and reflect to feature flags.
        let cached = Self.loadPurchasedCache(defaults)
        self.purchased = cached.ids
        self.entitlements.applyProducts(cached.ids)
        entitlementsSubject.send(cached.ids)

        // Load cached catalog (for offline price/UI) and then reconcile live.
        if let offlineCatalog = Self.loadCatalogCache() {
            self.products = offlineCatalog
            self.state = .ready
        }

        listenForTransactionUpdates()
        refreshSubscriptionStatuses() // non-fatal if nothing is a sub
    }

    deinit {
        updatesTask?.cancel()
        purchaseTask?.cancel()
        subsStatusTask?.cancel()
    }

    // MARK: - Public API

    /// Idempotent: loads and caches product metadata; uses on-disk cache on failure.
    public func loadProducts() async {
        state = .loading
        analytics?.log(event: .paywallCatalogLoadStarted)

        do {
            let ids = Set(ProductID.allCases.map(\.rawValue))
            let skProducts = try await Product.products(for: ids)

            // Deterministic order to keep UI stable.
            let ordering = ProductID.allCases.enumerated().reduce(into: [String: Int]()) { $0[$1.element.rawValue] = $1.offset }
            let localized: [Item] = skProducts.compactMap { p in
                guard let pid = ProductID(rawValue: p.id) else { return nil }
                return Item(
                    id: pid,
                    displayName: p.displayName,
                    description: p.description,
                    price: p.displayPrice,
                    currencyCode: p.priceFormatStyle.currency?.identifier,
                    localeIdentifier: Locale.current.identifier, // SK2 does not expose concrete price locale; we record device locale for context
                    isFamilyShareable: p.isFamilyShareable,
                    rawProduct: p,
                    kind: p.type
                )
            }
            .sorted { (lhs, rhs) in
                (ordering[lhs.id.rawValue] ?? .max) < (ordering[rhs.id.rawValue] ?? .max)
            }

            self.products = localized
            self.state = .ready
            Self.saveCatalogCache(localized)

            analytics?.log(event: .paywallCatalogLoadSucceeded)
            await refreshEntitlementsFromAppStore(silent: true)

        } catch {
            // Serve cached catalog on network failure.
            if let cached = Self.loadCatalogCache(),
               !Self.isCatalogExpired() {
                self.products = cached
                self.state = .ready
                analytics?.log(event: .paywallCatalogLoadRecoveredFromCache)
                log.notice("Product lookup failed; served cached catalog. \(error.localizedDescription, privacy: .public)")
            } else {
                self.state = .failed(message: "Product lookup failed")
                self.lastError = UXError.from(.unknown)
                analytics?.log(event: .paywallCatalogLoadFailed, error: error)
                log.error("Product lookup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Purchases a product (handles consumable, non-consumable, and subscriptions).
    public func purchase(_ id: ProductID) {
        guard purchaseTask == nil else { return }
        guard let item = products.first(where: { $0.id == id }) else {
            lastError = UXError.from(.unknown)
            return
        }

        purchaseTask = Task { [weak self] in
            guard let self else { return }
            self.state = .purchasing(id)
            analytics?.log(event: .purchaseStarted(product: id.rawValue))

            do {
                if !AppStore.canMakePayments { throw AppError.purchaseNotAllowed }

                // If we don't have a live Product (e.g., from cache-only), try to reload just this SKU.
                var product = item.rawProduct
                if product == nil {
                    product = try await Product.products(for: [id.rawValue]).first
                }
                guard let product else { throw AppError.productUnavailable }

                let result = try await product.purchase()

                switch result {
                case .success(let verification):
                    let transaction = try self.verify(verification)
                    await transaction.finish()

                    if transaction.productType == .consumable {
                        // Consumables are fire-and-forget. We don't add to entitlements.
                        analytics?.log(event: .consumableDelivered(product: transaction.productID))
                    } else {
                        self.applyPurchased(productId: transaction.productID)
                    }

                    self.state = .ready
                    self.analytics?.log(event: .purchaseSucceeded(product: id.rawValue))

                case .userCancelled:
                    self.state = .ready
                    self.lastError = UXError.from(.purchaseCancelled)
                    self.analytics?.log(event: .purchaseCancelled(product: id.rawValue))

                case .pending:
                    self.state = .ready
                    self.analytics?.log(event: .purchasePending(product: id.rawValue))
                    self.log.debug("Purchase pending for \(id.rawValue, privacy: .public).")

                @unknown default:
                    self.state = .failed(message: "Purchase failed")
                    self.lastError = UXError.from(.purchaseFailed)
                    self.analytics?.log(event: .purchaseFailed(product: id.rawValue), error: nil)
                }
            } catch let appErr as AppError {
                self.state = .ready
                self.lastError = UXError.from(appErr)
                self.analytics?.log(event: .purchaseFailed(product: id.rawValue), error: appErr)
            } catch {
                self.state = .ready
                self.lastError = UXError.from(.purchaseFailed)
                self.analytics?.log(event: .purchaseFailed(product: id.rawValue), error: error)
                self.log.error("Purchase failed: \(error.localizedDescription, privacy: .public)")
            }

            self.purchaseTask = nil
        }
    }

    /// Manual restore; also used by Entitlements.performRestorePurchases.
    @discardableResult
    public func restore() async -> Result<Set<ProductID>, AppError> {
        state = .restoring
        analytics?.log(event: .restoreStarted)
        do {
            let set = try await restorePurchases()
            applyPurchased(productIds: set)
            state = .ready
            analytics?.log(event: .restoreSucceeded(count: set.count))
            return .success(set)
        } catch let err as AppError {
            state = .ready
            lastError = UXError.from(err)
            analytics?.log(event: .restoreFailed, error: err)
            return .failure(err)
        } catch {
            state = .ready
            lastError = UXError.from(.restoreFailed)
            analytics?.log(event: .restoreFailed, error: error)
            return .failure(.restoreFailed)
        }
    }

    /// Re-sync entitlements from App Store (call on app start/foreground).
    public func refreshEntitlementsFromAppStore(silent: Bool = false) async {
        if !silent { state = .loading }
        do {
            let set = try await validProductsFromTransactions()
            applyPurchased(productIds: set)
            if !silent { state = .ready }
        } catch {
            if !silent {
                state = .failed(message: "Couldn’t refresh purchases")
                lastError = UXError.from(.restoreFailed)
            }
        }
    }

    /// Promotes Apple's code redemption sheet (offer codes).
    public func presentOfferCodeRedemption() {
        analytics?.log(event: .offerCodeRedemptionShown)
        SKPaymentQueue.default().presentCodeRedemptionSheet()
    }

    // MARK: - Internals (Transactions, Subscription Status, Revocations)

    private func listenForTransactionUpdates() {
        updatesTask?.cancel()
        updatesTask = Task { [weak self] in
            guard let self else { return }
            for await update in Transaction.updates {
                do {
                    let transaction = try self.verify(update)
                    await transaction.finish()

                    if let pid = ProductID(rawValue: transaction.productID) {
                        if let revocationDate = transaction.revocationDate {
                            // If revoked, drop entitlement and cache.
                            self.handleRevocation(product: pid, revocationDate: revocationDate)
                        } else {
                            // Normal grant path.
                            if transaction.productType != .consumable {
                                self.applyPurchased(productId: transaction.productID)
                            }
                        }
                    }
                } catch {
                    // ignore unverifiable updates
                }
            }
        }
    }

    private func verify<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let safe): return safe
        case .unverified: throw AppError.purchaseFailed
        }
    }

    /// Pull all current entitlements (non-consumables/subs) from transaction history.
    private func validProductsFromTransactions() async throws -> Set<ProductID> {
        var owned: Set<ProductID> = []

        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result else { continue }
            guard let pid = ProductID(rawValue: t.productID) else { continue }

            switch t.productType {
            case .nonConsumable, .nonRenewable, .autoRenewable:
                if t.revocationDate == nil { owned.insert(pid) }
            default:
                break
            }
        }
        return owned
    }

    private func handleRevocation(product: ProductID, revocationDate: Date) {
        purchased.remove(product)
        Self.savePurchasedCache(purchased, defaults: defaults)
        entitlements.applyProducts(purchased)
        entitlementsSubject.send(purchased)
        analytics?.log(event: .purchaseRevoked(product: product.rawValue))
        log.notice("Revoked entitlement for \(product.rawValue, privacy: .public) at \(revocationDate.description, privacy: .public)")
    }

    private func refreshSubscriptionStatuses() {
        subsStatusTask?.cancel()
        subsStatusTask = Task { [weak self] in
            guard let self else { return }
            // Best-effort: check any subscription products for billing issues, etc., to help PaywallRules.
            let subProducts = self.products.filter { $0.isSubscription }.compactMap { $0.rawProduct }
            for product in subProducts {
                // This call throws if status is unavailable; swallow errors.
                if let statuses = try? await product.subscription?.status {
                    // We don't need to persist details; this is a signal for paywall hints or UX affordances.
                    if statuses.contains(where: { $0.state == .expired || $0.state == .revoked }) {
                        analytics?.log(event: .subscriptionInactive(product: product.id))
                    }
                }
            }
        }
    }

    // MARK: - Apply & Persist

    private func applyPurchased(productId: String) {
        guard let pid = ProductID(rawValue: productId) else { return }
        applyPurchased(productIds: [pid])
    }

    private func applyPurchased(productIds: Set<ProductID>) {
        purchased.formUnion(productIds)
        Self.savePurchasedCache(purchased, defaults: defaults)
        entitlements.applyProducts(purchased)
        entitlementsSubject.send(purchased)
    }

    // MARK: - Restore (throws AppError for Entitlements.restore hook)

    private func restorePurchases() async throws -> Set<ProductID> {
        let set = try await validProductsFromTransactions()
        if set.isEmpty { throw AppError.restoreFailed }
        return set
    }

    // MARK: - Caching helpers

    private struct EntitlementCachePayload: Codable {
        let ids: [String]
        let updatedAt: Date
    }

    private static func loadPurchasedCache(_ defaults: UserDefaults) -> (ids: Set<ProductID>, fresh: Bool) {
        guard
            let data = defaults.data(forKey: purchasedCacheKey),
            let payload = try? JSONDecoder().decode(EntitlementCachePayload.self, from: data)
        else { return ([], false) }

        let set = Set(payload.ids.compactMap(ProductID.init(rawValue:)))
        let fresh = Date().timeIntervalSince(payload.updatedAt) < entitlementTTL
        return (set, fresh)
    }

    private static func savePurchasedCache(_ set: Set<ProductID>, defaults: UserDefaults) {
        let payload = EntitlementCachePayload(ids: set.map(\.rawValue), updatedAt: Date())
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: purchasedCacheKey)
        }
    }

    private struct CatalogCachePayload: Codable {
        let items: [Item]
        let updatedAt: Date
    }

    private static func loadCatalogCache() -> [Item]? {
        guard let data = try? Data(contentsOf: catalogCacheURL),
              let payload = try? JSONDecoder().decode(CatalogCachePayload.self, from: data)
        else { return nil }
        return payload.items
    }

    private static func saveCatalogCache(_ items: [Item]) {
        let payload = CatalogCachePayload(items: items.map { // strip rawProduct before writing
            Item(id: $0.id,
                 displayName: $0.displayName,
                 description: $0.description,
                 price: $0.price,
                 currencyCode: $0.currencyCode,
                 localeIdentifier: $0.localeIdentifier,
                 isFamilyShareable: $0.isFamilyShareable,
                 rawProduct: nil,
                 kind: $0.kind)
        }, updatedAt: Date())
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: catalogCacheURL, options: .atomic)
        }
    }

    private static func isCatalogExpired() -> Bool {
        guard let data = try? Data(contentsOf: catalogCacheURL),
              let payload = try? JSONDecoder().decode(CatalogCachePayload.self, from: data)
        else { return true }
        return Date().timeIntervalSince(payload.updatedAt) >= catalogTTL
    }
}

// MARK: - Preview / Test seam

#if DEBUG
@MainActor
public final class StoreFake: Store {
    public init(entitlements: Entitlements, owned: Set<ProductID> = [], analytics: AnalyticsLogger? = nil) {
        super.init(entitlements: entitlements,
                   analytics: analytics,
                   defaults: UserDefaults(suiteName: "StoreFake-\(UUID().uuidString)")!)
        self.purchased = owned
        entitlements.applyProducts(owned)
        self.products = ProductID.allCases.map {
            Item(id: $0,
                 displayName: "[\($0.rawValue)]",
                 description: "Fake product",
                 price: "$0.99",
                 currencyCode: "USD",
                 localeIdentifier: "en_US",
                 isFamilyShareable: true,
                 rawProduct: nil,
                 kind: .nonConsumable)
        }
        self.state = .ready
    }
}
#endif

// MARK: - UX helpers

public extension Store {
    var canMakePayments: Bool { AppStore.canMakePayments }

    func isUnlocked(_ feature: ProFeature) -> Bool {
        entitlements.has(feature)
    }

    func product(for feature: ProFeature) -> Item? {
        products.first { $0.id.unlocks.contains(feature) }
    }

    /// Family sharing flag for a given product (UI hint).
    func isFamilyShareable(_ id: ProductID) -> Bool {
        products.first(where: { $0.id == id })?.isFamilyShareable ?? false
    }
}

// MARK: - Error bridging

private extension UXError {
    static var purchaseCancelled: UXError { UXError.from(.purchaseCancelled) }
    static var purchaseFailed: UXError { UXError.from(.purchaseFailed) }
}

// MARK: - AppStore capability

private enum AppStore {
    static var canMakePayments: Bool {
        SKPaymentQueue.canMakePayments()
    }
}
