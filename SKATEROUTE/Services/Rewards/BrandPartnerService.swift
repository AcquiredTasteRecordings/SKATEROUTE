// Services/Rewards/BrandPartnerService.swift
// Local business promos → coupon issuance + QR validation.
// - Issues signed, short-TTL QR tokens (Ed25519) for partner-redeemable coupons.
// - Offline validation path (signature + TTL + replay/duplicate defense), with later server confirm hook.
// - Role-gated access for partner operators. No secrets hard-coded; keys come from PartnerAPI/RemoteConfig.
// - Integrates with RewardsWallet to store/display coupons and redemption state.

import Foundation
import Combine
import CryptoKit
import CoreLocation
import os.log

// MARK: - Public models (keep lean + Codable)

public struct PartnerOffer: Codable, Hashable, Identifiable {
    public let id: String               // offer template id (e.g., "cafe-latte-bogo-v1")
    public let partnerId: String        // business id
    public let title: String
    public let details: String?
    public let validityStart: Date?
    public let validityEnd: Date?       // coupon expiration if issued now defaults here
    public let maxRedemptions: Int      // 1 for single-use, >1 for punch-card style
    public init(id: String,
                partnerId: String,
                title: String,
                details: String? = nil,
                validityStart: Date? = nil,
                validityEnd: Date? = nil,
                maxRedemptions: Int = 1) {
        self.id = id; self.partnerId = partnerId; self.title = title; self.details = details
        self.validityStart = validityStart; self.validityEnd = validityEnd; self.maxRedemptions = maxRedemptions
    }
}

/// Compact JWT-ish claims for QR payloads (signed).
public struct QRTokenClaims: Codable, Hashable {
    public let ver: Int = 1
    public let iss: String             // "skateroute" or partner issuer namespace
    public let partnerId: String
    public let couponId: String
    public let userId: String
    public let exp: TimeInterval       // epoch seconds (absolute expiry)
    public let jti: String             // nonce (prevents replay)
}

/// Result after scanning/validating a QR token (partner side).
public enum QRValidationResult: Equatable {
    case valid(partnerId: String, couponId: String, userId: String, jti: String, expiresAt: Date)
    case expired
    case invalidSignature
    case wrongPartner
    case duplicate
    case malformed
    case notAuthorized                 // partner device/user lacks role
}

// MARK: - DI seams

/// Wallet sink/source for coupons (already implemented).
public protocol RewardsWalletReadableWritable {
    func issueCoupon(_ c: PartnerCoupon)
    @discardableResult func redeemCoupon(id: String) -> Bool
    var snapshotPublisher: AnyPublisher<RewardsSnapshot, Never> { get }
}

/// PartnerAPI adapter: fetch partner public keys & post redemption confirmations (best-effort).
public protocol PartnerAPIClient {
    /// Map of partnerId → Ed25519 public key (raw 32 bytes).
    func fetchPartnerKey(partnerId: String) async throws -> Data
    /// Confirm redemption (async, fire-and-forget acceptable).
    func confirmRedemption(partnerId: String, couponId: String, userId: String, jti: String, redeemedAt: Date) async
}

/// Role gate for partner operators (a partner employee / kiosk mode).
public protocol PartnerRoleGating {
    func isAuthorizedOperator(for partnerId: String) -> Bool
}

/// Signing for issuing QR payloads (prod: server should mint; client signer exists for offline/test or delegated issuance).
public protocol QRTokenSigning {
    /// Ed25519 private key bytes (raw 32) used to sign claims or nil to skip local issuance.
    var privateKey: Data? { get }
    /// Issuer string to embed (e.g., "skateroute")
    var issuer: String { get }
}

// MARK: - Service

@MainActor
public final class BrandPartnerService: ObservableObject {

    public enum State: Equatable { case idle, ready, error(String) }

    @Published public private(set) var state: State = .idle

    // Streams for UI (e.g., PartnerSpotlightView can subscribe to wallet snapshot directly)
    public var walletSnapshotPublisher: AnyPublisher<RewardsSnapshot, Never> { wallet.snapshotPublisher }

    // DI
    private let wallet: RewardsWalletReadableWritable
    private let api: PartnerAPIClient
    private let roles: PartnerRoleGating
    private let signer: QRTokenSigning
    private let log = Logger(subsystem: "com.skateroute", category: "BrandPartnerService")

    // Key registry cache (partnerId → public key)
    private var publicKeyCache: [String: Data] = [:]

    // Duplicate scan defense (recently seen jti with TTL)
    private var seenJTI: [String: Date] = [:]
    private let jtiMemorySeconds: TimeInterval = 6 * 3600

    // Clock
    private let now: () -> Date

    public init(wallet: RewardsWalletReadableWritable,
                api: PartnerAPIClient,
                roles: PartnerRoleGating,
                signer: QRTokenSigning,
                now: @escaping () -> Date = { Date() }) {
        self.wallet = wallet
        self.api = api
        self.roles = roles
        self.signer = signer
        self.now = now
        self.state = .ready
        pruneSeenJTIs()
    }

    // MARK: Coupon issuance (user’s device)

    /// Issue a coupon into the user’s wallet for a given offer.
    /// If a server-signed payload is provided, it will be used. Else, we locally sign a short-TTL token (DEBUG / kiosk).
    public func issueCoupon(for offer: PartnerOffer,
                            userId: String,
                            serverSignedQR payload: String? = nil,
                            expOverride: Date? = nil) async {
        let couponId = UUID().uuidString
        let exp = expOverride ?? offer.validityEnd
        let qrPayload: String
        if let s = payload {
            qrPayload = s
        } else if let pvt = signer.privateKey {
            // Local issuance (only when explicitly enabled by DI). Short TTL (e.g., 24h) if no validityEnd.
            let ttl = min(24 * 3600, max(5 * 60, (exp?.timeIntervalSince1970 ?? (now().addingTimeInterval(24*3600).timeIntervalSince1970)) - now().timeIntervalSince1970))
            let claims = QRTokenClaims(iss: signer.issuer,
                                       partnerId: offer.partnerId,
                                       couponId: couponId,
                                       userId: userId,
                                       exp: now().addingTimeInterval(ttl).timeIntervalSince1970,
                                       jti: UUID().uuidString)
            qrPayload = BrandPartnerService.signClaims(claims, privateKey: pvt)
        } else {
            // No signer available: emit an unsigned placeholder that will fail offline validation (use server path).
            let claims = QRTokenClaims(iss: "unsigned", partnerId: offer.partnerId, couponId: couponId, userId: userId, exp: now().addingTimeInterval(5*60).timeIntervalSince1970, jti: UUID().uuidString)
            qrPayload = BrandPartnerService.packUnsigned(claims)
        }

        let coupon = PartnerCoupon(id: couponId,
                                   partnerId: offer.partnerId,
                                   title: offer.title,
                                   details: offer.details,
                                   qrPayload: qrPayload,
                                   issuedAt: now(),
                                   expiresAt: offer.validityEnd,
                                   maxRedemptions: offer.maxRedemptions)
        wallet.issueCoupon(coupon)
    }

    // MARK: QR Validation (partner side, offline-first)

    /// Validate a scanned token for a specific partner. Role-gated. No network required.
    public func validate(scanned token: String, for partnerId: String) async -> QRValidationResult {
        guard roles.isAuthorizedOperator(for: partnerId) else { return .notAuthorized }
        guard let (claims, sig, content) = BrandPartnerService.unpack(token) else { return .malformed }
        // Partner binding
        guard claims.partnerId == partnerId else { return .wrongPartner }
        // TTL
        let expiresAt = Date(timeIntervalSince1970: claims.exp)
        guard now() < expiresAt else { return .expired }
        // Replay defense
        if let t = seenJTI[claims.jti], now().timeIntervalSince(t) < jtiMemorySeconds { return .duplicate }

        // Signature check
        do {
            let pub = try await publicKey(for: partnerId) // Ed25519 public key bytes
            guard BrandPartnerService.verifySignature(sig, content: content, publicKey: pub) else {
                return .invalidSignature
            }
        } catch {
            log.error("Key fetch failed: \(error.localizedDescription, privacy: .public)")
            // Without key we cannot validate; treat as invalid
            return .invalidSignature
        }

        // Mark as seen to prevent immediate double-scan abuse
        seenJTI[claims.jti] = now()
        pruneSeenJTIs()

        return .valid(partnerId: partnerId, couponId: claims.couponId, userId: claims.userId, jti: claims.jti, expiresAt: expiresAt)
    }

    /// After a VALID result, commit redemption locally and fire best-effort server confirm.
    public func commitRedemption(_ result: QRValidationResult) async {
        guard case let .valid(pid, couponId, userId, jti, _) = result else { return }
        _ = wallet.redeemCoupon(id: couponId) // single-claim/limits enforced by wallet
        Task.detached { [api, now] in
            await api.confirmRedemption(partnerId: pid, couponId: couponId, userId: userId, jti: jti, redeemedAt: now())
        }
    }

    // MARK: Key registry

    private func publicKey(for partnerId: String) async throws -> Data {
        if let k = publicKeyCache[partnerId] { return k }
        let k = try await api.fetchPartnerKey(partnerId: partnerId)
        publicKeyCache[partnerId] = k
        return k
    }

    private func pruneSeenJTIs() {
        let cutoff = now().addingTimeInterval(-jtiMemorySeconds)
        seenJTI = seenJTI.filter { $0.value > cutoff }
    }

    // MARK: Token pack/sign/verify (compact Base64URL)

    /// token = base64url(jsonClaims) + "." + base64url(signature)
    /// signature = Ed25519.sign(claimsJSON, privateKey)
    private static func signClaims(_ claims: QRTokenClaims, privateKey: Data) -> String {
        let payload = try! JSONEncoder().encode(claims)
        let contentB64 = base64url(payload)
        let pk = try! Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        let sig = try! pk.signature(for: payload)
        return contentB64 + "." + base64url(sig)
    }

    private static func verifySignature(_ sigB: Data, content: Data, publicKey: Data) -> Bool {
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return (try? pub.isValidSignature(sigB, for: content)) ?? false
    }

    private static func unpack(_ token: String) -> (claims: QRTokenClaims, sig: Data, content: Data)? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let content = base64urlDecode(String(parts[0])),
              let sig = base64urlDecode(String(parts[1])),
              let claims = try? JSONDecoder().decode(QRTokenClaims.self, from: content) else { return nil }
        return (claims, sig, content)
    }

    private static func packUnsigned(_ claims: QRTokenClaims) -> String {
        base64url(try! JSONEncoder().encode(claims)) + "."
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64urlDecode(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = 4 - (str.count % 4)
        if pad < 4 { str.append(String(repeating: "=", count: pad)) }
        return Data(base64Encoded: str)
    }
}

// MARK: - DEBUG / Test fakes

#if DEBUG
public struct LocalSigner: QRTokenSigning {
    public let privateKey: Data?
    public let issuer: String
    public init(privateKey: Data? = try? Curve25519.Signing.PrivateKey().rawRepresentation, issuer: String = "skateroute-local") {
        self.privateKey = privateKey; self.issuer = issuer
    }
}

public final class PartnerAPIFake: PartnerAPIClient {
    public var pubKeys: [String: Data] = [:]
    public private(set) var confirmations: [(String, String, String, String, Date)] = []
    public init() {}
    public func fetchPartnerKey(partnerId: String) async throws -> Data {
        if let k = pubKeys[partnerId] { return k }
        throw NSError(domain: "PartnerAPIFake", code: 404)
    }
    public func confirmRedemption(partnerId: String, couponId: String, userId: String, jti: String, redeemedAt: Date) async {
        confirmations.append((partnerId, couponId, userId, jti, redeemedAt))
    }
}

public struct PartnerRolesFake: PartnerRoleGating {
    public var allowed: Set<String>
    public init(allowed: Set<String> = []) { self.allowed = allowed }
    public func isAuthorizedOperator(for partnerId: String) -> Bool { allowed.contains(partnerId) }
}

/// Wallet shim for tests to observe state transitions.
public final class RewardsWalletShim: RewardsWalletReadableWritable {
    public private(set) var issued: [PartnerCoupon] = []
    public private(set) var redeemed: Set<String> = []
    private let subject = CurrentValueSubject<RewardsSnapshot, Never>(RewardsSnapshot(badges: [], coupons: []))
    public var snapshotPublisher: AnyPublisher<RewardsSnapshot, Never> { subject.eraseToAnyPublisher() }
    public func issueCoupon(_ c: PartnerCoupon) {
        issued.append(c)
        subject.send(RewardsSnapshot(badges: [], coupons: issued))
    }
    public func redeemCoupon(id: String) -> Bool {
        if redeemed.contains(id) { return false }
        redeemed.insert(id)
        return true
    }
}
#endif

// MARK: - Integration notes
// • AppDI: provide BrandPartnerService as a singleton. Inject real RewardsWallet, PartnerAPI (REST), PartnerRoles (from auth/role claims),
//   and a signer (usually empty in PROD because server issues signed tokens; enable LocalSigner in DEBUG/demo kiosk).
// • Partner keys distribution: use PartnerAPI + RemoteConfig to distribute Ed25519 public keys per partner. No private keys in app.
// • UI:
//    - PartnerSpotlightView → “Add to Wallet” calls issueCoupon(for:userId:serverSignedQR:).
//    - RewardsWalletView shows QR (already supported by RewardsWallet.couponQRPNG()).
//    - PartnerDashboardView (role-gated) scans, then calls validate(scanned:for:). If `.valid`, call commitRedemption(_:) and show success.

// MARK: - Test plan
// 1) Duplicate scan defense:
//    - Create signer + keypair, put public key in PartnerAPIFake for pid.
//    - issueCoupon(...); extract token from issued[0].qrPayload; validate once -> .valid; validate again immediately -> .duplicate.
// 2) TTL expiry:
//    - Build claims with exp in the past (expOverride). validate -> .expired.
// 3) Partner role gate:
//    - roles.allowed excludes pid -> validate -> .notAuthorized; includes pid -> proceeds.
// 4) Signature invalid:
//    - Corrupt last char of payload -> .invalidSignature.
// 5) Wrong partner binding:
//    - Validate token for a different partnerId than claims.partnerId -> .wrongPartner.
// 6) Commit redemption & confirm:
//    - After `.valid`, call commitRedemption -> wallet.redeemCoupon called (returns true) and PartnerAPIFake.confirmations appended.
// 7) Unsigned payload path (server not provided & signer.privateKey == nil):
//    - issueCoupon produces "unsigned" token; validate -> .invalidSignature (by design), forcing online path in PROD.
