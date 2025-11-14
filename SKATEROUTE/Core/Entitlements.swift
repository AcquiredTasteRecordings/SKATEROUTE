// Core/Entitlements.swift
// Central feature gates for the SkateRoute app.
// Zero secrets, App Store–friendly, privacy-safe. Works standalone and plugs into StoreKit later.
// Responsibilities:
//   • Define paywalled features and product identifiers.
//   • Persist entitlements locally (UserDefaults) and expose a reactive API.
//   • Accept purchase/restoration results and receipt-validation callbacks (when available).
//   • Provide human-readable labels for UI (PaywallView, Settings).
//
// This file does NOT perform purchases. It only models access and state.

import Foundation
import Combine

// MARK: - Features gated by entitlements

/// Add new features here and wire to product ids below.
/// Keep cases stable — they are persisted in UserDefaults.
public enum ProFeature: String, CaseIterable, Codable, Sendable, Hashable {
    /// Downloaded map manifests and future tile payloads.
    case offlinePacks
    /// Extra analytics panes (local device analytics, NOT ads).
    case advancedAnalytics
    /// Full media editor (all overlays, export presets, no watermark).
    case proEditor
}

public extension ProFeature {
    var displayName: String {
        switch self {
        case .offlinePacks:     return NSLocalizedString("Offline Packs", comment: "Entitlement name")
        case .advancedAnalytics:return NSLocalizedString("Advanced Analytics", comment: "Entitlement name")
        case .proEditor:        return NSLocalizedString("Pro Editor", comment: "Entitlement name")
        }
    }

    var marketingBlurb: String {
        switch self {
        case .offlinePacks:
            return NSLocalizedString("Save routes and ride with confidence when you’re off the grid.", comment: "Entitlement blurb")
        case .advancedAnalytics:
            return NSLocalizedString("Deeper ride stats, grade heatmaps, and session insights.", comment: "Entitlement blurb")
        case .proEditor:
            return NSLocalizedString("Trim, speed, overlays, and clean exports ready to share.", comment: "Entitlement blurb")
        }
    }
}

// MARK: - Product identifiers

/// Centralizes StoreKit product identifiers so there’s one source of truth.
/// Canonical format matches App Store Connect SKUs: `com.skateroute.app.pro.<feature>`.
public enum ProductID: String, CaseIterable, Sendable {
    // Non-consumables (one-time unlocks)
    case offlinePacks = "com.skateroute.app.pro.offline"
    case advancedAnalytics = "com.skateroute.app.pro.analytics"
    case proEditor = "com.skateroute.app.pro.editor"

    // If you add subscriptions later, create a separate enum to avoid mixing types.
}

public extension ProductID {
    /// Map product → feature(s). Supports a product unlocking multiple features.
    var unlocks: Set<ProFeature> {
        switch self {
        case .offlinePacks:      return [.offlinePacks]
        case .advancedAnalytics: return [.advancedAnalytics]
        case .proEditor:         return [.proEditor]
        }
    }
}

// MARK: - Entitlement store (persisted locally)

/// Persistence namespace to avoid collisions.
private enum EntitlementsKeys {
    static let store = "Entitlements.Store.v1"
    static let granted = "granted" // [String]
    static let lastRefresh = "lastRefresh" // ISO8601
}

/// Public, reactive model for entitlement state.
/// Own one instance in DI (`LiveAppDI.entitlements`) and inject everywhere.
@MainActor
public final class Entitlements: ObservableObject {

    // Published union of unlocked features
    @Published public private(set) var granted: Set<ProFeature> = []

    /// Last time we refreshed from a canonical source (receipt/server).
    @Published public private(set) var lastRefresh: Date?

    /// Readonly stream for non-SwiftUI consumers.
    public var publisher: AnyPublisher<Set<ProFeature>, Never> { $granted.eraseToAnyPublisher() }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Optional hook to a receipt validator (plugged in by Services/StoreKit/ReceiptValidator).
    public var validateReceipt: (() async throws -> Set<ProductID>)?

    /// Optional hook to a “restore purchases” action (usually triggers a StoreKit flow elsewhere).
    public var performRestorePurchases: (() async throws -> Set<ProductID>)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadFromDisk()
    }

    // MARK: - Querying

    public func has(_ feature: ProFeature) -> Bool {
        granted.contains(feature)
    }

    /// Gate a feature with a friendly reason string (for diagnostics/UX).
    public func access(for feature: ProFeature) -> Access {
        if has(feature) { return .granted }
        return .locked(reason: feature.marketingBlurb)
    }

    public enum Access: Equatable, Sendable {
        case granted
        case locked(reason: String)
    }

    // MARK: - Mutations (from purchase, restore, or validation)

    /// Call this when a purchase completes successfully with the purchased product id.
    public func applyPurchase(product: ProductID) {
        var new = granted
        new.formUnion(product.unlocks)
        updateAndPersist(new, touched: Date())
    }

    /// Apply a set of products (e.g., from restore or validated receipt).
    public func applyProducts(_ products: Set<ProductID>, refreshedAt: Date = Date()) {
        let unlocked = products.reduce(into: Set<ProFeature>()) { acc, p in
            acc.formUnion(p.unlocks)
        }
        let merged = granted.union(unlocked)
        updateAndPersist(merged, touched: refreshedAt)
    }

    /// Explicitly set features (debug tools or server-authoritative).
    public func setFeatures(_ features: Set<ProFeature>, refreshedAt: Date = Date()) {
        updateAndPersist(features, touched: refreshedAt)
    }

    /// Run the async receipt validator (if provided) and apply results.
    public func refreshFromReceipt() async {
        guard let validator = validateReceipt else { return }
        do {
            let products = try await validator()
            applyProducts(products, refreshedAt: Date())
        } catch {
            // Silent failure is fine; UI can show manual restore.
        }
    }

    /// Trigger the configured restore flow (if any), then merge.
    public func restorePurchases() async throws {
        guard let restore = performRestorePurchases else { return }
        let products = try await restore()
        applyProducts(products, refreshedAt: Date())
    }

    // MARK: - Free tier logic (soft gates)

    /// Free tier allowances that don’t require a purchase, expressed as feature checks the UI can query.
    /// Example usage: gate an action until quota is exhausted; then show paywall.
    public struct FreeTier: Sendable, Equatable {
        /// e.g., number of offline routes you can keep without Pro.
        public var offlinePacksQuota: Int = 2
        /// Allow basic trims without overlays in the editor.
        public var proEditorLiteEnabled: Bool = true
        /// Enable summary-only analytics without drill-downs.
        public var analyticsSummaryEnabled: Bool = true
    }

    public let freeTier = FreeTier()

    // MARK: - Debug helpers (compile-time)

    #if DEBUG
    /// Grant all features in DEBUG for screenshots/previews (opt-in).
    public func grantAllForDebug() {
        updateAndPersist(Set(ProFeature.allCases), touched: Date())
    }
    #endif

    // MARK: - Private

    private func updateAndPersist(_ features: Set<ProFeature>, touched: Date) {
        granted = features
        lastRefresh = touched
        persistToDisk()
    }

    private func loadFromDisk() {
        guard let blob = defaults.data(forKey: EntitlementsKeys.store) else { return }
        do {
            let container = try decoder.decode(Persisted.self, from: blob)
            granted = Set(container.granted.compactMap(ProFeature.init(rawValue:)))
            if let ts = container.lastRefreshISO8601 {
                lastRefresh = ISO8601DateFormatter().date(from: ts)
            }
        } catch {
            // Corrupt state: wipe and continue cleanly
            defaults.removeObject(forKey: EntitlementsKeys.store)
            granted = []
            lastRefresh = nil
        }
    }

    private func persistToDisk() {
        let iso = ISO8601DateFormatter()
        let container = Persisted(
            granted: granted.map(\.rawValue),
            lastRefreshISO8601: lastRefresh.map { iso.string(from: $0) }
        )
        if let data = try? encoder.encode(container) {
            defaults.set(data, forKey: EntitlementsKeys.store)
        }
    }

    private struct Persisted: Codable {
        let granted: [String]
        let lastRefreshISO8601: String?
    }
}

// MARK: - UI helpers (optional; safe to remove if you prefer MVVM-only)

public extension Entitlements.ProposedCTA {
    /// Which CTA should we show on a paywall tile for a feature, given current state.
    @MainActor static func forFeature(_ feature: ProFeature, entitlements: Entitlements) -> Entitlements.ProposedCTA {
        entitlements.has(feature) ? .manage : .purchase
    }
}

public extension Entitlements {
    enum ProposedCTA: Sendable {
        case purchase
        case manage
    }
}

// MARK: - Minimal test seam

#if DEBUG
/// Deterministic fake for tests and previews.
@MainActor
public final class EntitlementsFake: Entitlements {
    public init(granted: Set<ProFeature>) {
        super.init(defaults: UserDefaults(suiteName: "EntitlementsFake-\(UUID().uuidString)")!)
        setFeatures(granted)
    }
}
#endif


