// Services/StoreKit/ReceiptValidator.swift
// Local “validation” using StoreKit 2 verified transactions and subscription status.
// Hardened without PKCS#7 parsing. Signature is enforced via SK2 VerificationResult.
// No secrets; ATT-free. Designed for unit tests with fakes.

import Foundation
import StoreKit
import OSLog

@MainActor
public final class ReceiptValidator: NSObject {

    // MARK: - Types

    public enum Environment: String, Sendable, Codable {
        case sandbox, production, unknown
    }

    public struct Diagnostics: Sendable, Codable {
        public let environment: Environment
        public let hasReceiptFile: Bool
        public let receiptByteCount: Int
        public let lastValidatedAt: Date
        public let anomalies: [Anomaly]
    }

    public enum Anomaly: String, Sendable, Codable, CaseIterable {
        case missingReceipt
        case unverifiedSignature
        case bundleMismatch
        case appVersionMismatch
        case revokedTransaction
        case expiredSubscription
        case inGracePeriod
        case subscriptionBillingIssue
    }

    public struct SubscriptionStatusInfo: Sendable, Codable {
        public let productId: String
        public let state: Product.SubscriptionInfo.Status.State
        public let willAutoRenew: Bool
        public let inGracePeriod: Bool
        public let graceExpiresAt: Date?
        public let originalPurchaseDate: Date?
        public let expirationDate: Date?
    }

    public struct ValidationResult: Sendable, Codable {
        public let environment: Environment
        public let ownedProducts: Set<ProductID>
        public let subscriptions: [SubscriptionStatusInfo]
        public let anomalies: [Anomaly]
        public let lastValidatedAt: Date
    }

    // MARK: - State

    private let log = Logger(subsystem: "com.yourcompany.skateroute", category: "ReceiptValidator")
    private(set) public var lastDiagnostics: Diagnostics?

    // MARK: - Public API (simple)

    /// Backward-compatible: returns owned products. Internally performs full validation.
    public func validateOwnedProducts() async throws -> Set<ProductID> {
        let result = try await validate()
        // update diagnostics snapshot for Settings/Diagnostics
        lastDiagnostics = Diagnostics(
            environment: result.environment,
            hasReceiptFile: hasReceiptFile,
            receiptByteCount: receiptData()?.count ?? 0,
            lastValidatedAt: result.lastValidatedAt,
            anomalies: result.anomalies
        )
        return result.ownedProducts
    }

    // MARK: - Public API (rich)

    /// Full validation. Prefer this from Store on app start / post-purchase for harder signals.
    public func validate() async throws -> ValidationResult {
        var anomalies: Set<Anomaly> = []

        // Environment & receipt presence
        let env = environment
        if !hasReceiptFile { anomalies.insert(.missingReceipt) }

        // Attempt fast path via verified transactions
        var owned = Set<ProductID>()
        var anyExpiredSub = false
        var anyRevoked = false
        var bundleMismatch = false
        var versionMismatch = false

        let bundleId = Bundle.main.bundleIdentifier
        let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String

        // Iterate current entitlements (non-consumables + subs)
        for await result in Transaction.currentEntitlements {
            switch result {
            case .unverified:
                anomalies.insert(.unverifiedSignature)
                continue
            case .verified(let t):
                // Hardening checks
                if let expected = bundleId, t.appBundleID != expected { bundleMismatch = true }
                if let expectedBuild = buildVersion, t.appVersion != expectedBuild { versionMismatch = true }

                if let pid = ProductID(rawValue: t.productID) {
                    if t.revocationDate != nil { anyRevoked = true }
                    switch t.productType {
                    case .nonConsumable, .nonRenewable, .autoRenewable:
                        owned.insert(pid)
                    default:
                        break
                    }
                }
            }
        }

        if bundleMismatch { anomalies.insert(.bundleMismatch) }
        if versionMismatch { anomalies.insert(.appVersionMismatch) }
        if anyRevoked { anomalies.insert(.revokedTransaction) }

        // If we still have nothing and no receipt, try refresh once.
        if owned.isEmpty, !hasReceiptFile {
            do {
                try await refreshReceipt()
                // Re-run ownership scan briefly
                for await result in Transaction.currentEntitlements {
                    if case .verified(let t) = result, let pid = ProductID(rawValue: t.productID) {
                        switch t.productType {
                        case .nonConsumable, .nonRenewable, .autoRenewable: owned.insert(pid)
                        default: break
                        }
                    }
                }
            } catch {
                log.error("Receipt refresh failed: \(error.localizedDescription, privacy: .public)")
                // Keep going; soft-degrade.
            }
        }

        // Subscription status sweep (renewal/grace/billing issues)
        var subs: [SubscriptionStatusInfo] = []
        // Try to fetch Product objects for all known SKUs so we can query status.
        let allKnownIds = Set(ProductID.allCases.map(\.rawValue))
        if !allKnownIds.isEmpty {
            do {
                let skProducts = try await Product.products(for: allKnownIds)
                for product in skProducts where product.type == .autoRenewable {
                    if let statuses = try? await product.subscription?.status {
                        for s in statuses {
                            let renewal = s.renewalInfo
                            // Grace period & expiration windows
                            let inGrace = (try? s.isInBillingGracePeriod) ?? false
                            if inGrace { anomalies.insert(.inGracePeriod) }
                            if s.state == .expired { anyExpiredSub = true }

                            let info = SubscriptionStatusInfo(
                                productId: product.id,
                                state: s.state,
                                willAutoRenew: renewal?.willAutoRenew ?? false,
                                inGracePeriod: inGrace,
                                graceExpiresAt: renewal?.gracePeriodExpirationDate,
                                originalPurchaseDate: s.transaction?.originalPurchaseDate,
                                expirationDate: s.transaction?.expirationDate
                            )
                            subs.append(info)

                            // Billing issue heuristic
                            if s.state == .inBillingRetry || s.state == .revoked {
                                anomalies.insert(.subscriptionBillingIssue)
                            }
                        }
                    }
                }
            } catch {
                // Status resolution is best-effort; don’t fail validation for this.
                log.notice("Subscription status lookup skipped: \(error.localizedDescription, privacy: .public)")
            }
        }

        if anyExpiredSub { anomalies.insert(.expiredSubscription) }

        let result = ValidationResult(
            environment: env,
            ownedProducts: owned,
            subscriptions: subs,
            anomalies: Array(anomalies),
            lastValidatedAt: Date()
        )

        // Snapshot diagnostics for UI
        lastDiagnostics = Diagnostics(
            environment: env,
            hasReceiptFile: hasReceiptFile,
            receiptByteCount: receiptData()?.count ?? 0,
            lastValidatedAt: result.lastValidatedAt,
            anomalies: result.anomalies
        )
        return result
    }

    // MARK: - Receipt refresh

    /// Attempts a best-effort receipt refresh (may prompt for App Store auth).
    public func refreshReceipt() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let request = SKReceiptRefreshRequest(receiptProperties: nil)
            let delegate = RefreshDelegate { result in
                switch result {
                case .success: cont.resume()
                case .failure(let err): cont.resume(throwing: err)
                }
            }
            request.delegate = delegate
            delegate.start(request: request)
        }
    }

    // MARK: - Environment & Receipt presence

    public var environment: Environment {
        guard let url = Bundle.main.appStoreReceiptURL else { return .unknown }
        if url.lastPathComponent == "sandboxReceipt" { return .sandbox }
        if url.lastPathComponent == "receipt" { return .production }
        return hasReceiptFile ? .sandbox : .unknown
    }

    public var hasReceiptFile: Bool {
        guard let url = Bundle.main.appStoreReceiptURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Internals

    private func receiptData() -> Data? {
        guard let url = Bundle.main.appStoreReceiptURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }
}

// MARK: - SKRequest delegate shim (self-retaining during request)

private final class RefreshDelegate: NSObject, SKRequestDelegate {
    enum Result { case success; case failure(Error) }
    private var onFinish: ((Result) -> Void)?
    private var strongSelf: RefreshDelegate?

    init(onFinish: @escaping (Result) -> Void) { self.onFinish = onFinish }

    func start(request: SKRequest) {
        strongSelf = self
        request.delegate = self
        request.start()
    }

    func requestDidFinish(_ request: SKRequest) {
        onFinish?(.success)
        cleanup()
    }

    func request(_ request: SKRequest, didFailWithError error: Error) {
        onFinish?(.failure(error))
        cleanup()
    }

    private func cleanup() {
        onFinish = nil
        strongSelf = nil
    }
}

// MARK: - DEBUG fakes

#if DEBUG
@MainActor
public final class ReceiptValidatorFake: ReceiptValidator {
    private let simulated: Set<ProductID>
    private let simulatedEnv: Environment
    private let simulatedAnomalies: [Anomaly]
    private let simulatedSubs: [SubscriptionStatusInfo]

    public init(products: Set<ProductID>,
                env: Environment = .sandbox,
                anomalies: [Anomaly] = [],
                subs: [SubscriptionStatusInfo] = []) {
        self.simulated = products
        self.simulatedEnv = env
        self.simulatedAnomalies = anomalies
        self.simulatedSubs = subs
        super.init()
    }

    public override var environment: Environment { simulatedEnv }
    public override var hasReceiptFile: Bool { true }

    public override func validateOwnedProducts() async throws -> Set<ProductID> {
        _ = try await validate() // keep diagnostics in sync
        return simulated
    }

    public override func validate() async throws -> ValidationResult {
        let result = ValidationResult(
            environment: simulatedEnv,
            ownedProducts: simulated,
            subscriptions: simulatedSubs,
            anomalies: simulatedAnomalies,
            lastValidatedAt: Date()
        )
        self.lastDiagnostics = Diagnostics(
            environment: simulatedEnv,
            hasReceiptFile: true,
            receiptByteCount: 1024,
            lastValidatedAt: result.lastValidatedAt,
            anomalies: simulatedAnomalies
        )
        return result
    }

    public override func refreshReceipt() async throws { /* no-op */ }
}
#endif
