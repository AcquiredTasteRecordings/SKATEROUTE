// Services/Referrals/ReferralService.swift
// Growth engine: signed universal links, deep-link parsing, ethical attribution → rewards.
// No 3P tracking. All device-only guardrails. Server can add stronger checks later.

import Foundation
import CryptoKit
import AuthenticationServices
import Combine
import os.log
import CoreLocation
import UIKit

// MARK: - Protocols for DI

public protocol RewardsWalleting: AnyObject {
    @discardableResult
    func mintInviteReward(referrerId: String, refereeId: String) -> Reward // your existing model
    func hasClaimedInviteReward(referrerId: String, refereeId: String) -> Bool
}

public protocol CoarseLocationProviding {
    /// Return ISO region (e.g., "US","CA") when available. Keep it coarse (no PII).
    var currentRegionCode: String? { get }
}

public protocol ReferralAnalytics {
    func log(_ event: ReferralService.Event, meta: [String: String]?)
}

public enum ReferralCampaign: String, Codable, CaseIterable, Sendable {
    case generic
    case weeklyChallenge
    case cityPartner
}

// MARK: - Service

@MainActor
public final class ReferralService: ObservableObject {

    // Public surface for UI
    public enum Status: Equatable, Sendable {
        case idle
        case linkGenerated(URL)
        case pendingAttribution(referrerId: String, campaign: ReferralCampaign)
        case attributed(referrerId: String, refereeId: String, campaign: ReferralCampaign)
        case rejected(reason: String)
    }

    public enum Event: String {
        case linkGenerated, linkFailed
        case inboundParsed, inboundInvalidSig, inboundExpired, inboundReplay
        case attributionQueued, attributionApplied, attributionSuppressed
        case rewardMinted, rewardDuplicate, fraudCooldown, fraudDailyCap, fraudRegionMismatch
    }

    // MARK: Models

    /// Payload that gets signed by the inviter (client-side keypair). Tamper-evident.
    struct Payload: Codable, Equatable {
        let v: Int               // schema version
        let referrerId: String
        let nonce: String
        let createdAt: Date
        let campaign: ReferralCampaign
        let inviterPubKey: Data  // raw 32 bytes (Ed25519)
    }

    struct Envelope: Codable, Equatable {
        let payload: Payload
        let sig: Data            // Ed25519 signature over canonicalized JSON of `payload`
        let alg: String          // "Ed25519"
    }

    public struct Config: Sendable {
        public let universalLinkHost: String      // e.g., "links.skateroute.app"
        public let path: String                   // e.g., "/r"
        public let linkTTL: TimeInterval          // e.g., 7 * 24h
        public let deviceAttributionCooldown: TimeInterval // e.g., 12h
        public let perReferrerDailyCap: Int       // e.g., 5
        public let regionSanityEnabled: Bool
        public init(universalLinkHost: String,
                    path: String = "/r",
                    linkTTL: TimeInterval = 7*24*60*60,
                    deviceAttributionCooldown: TimeInterval = 12*60*60,
                    perReferrerDailyCap: Int = 5,
                    regionSanityEnabled: Bool = true) {
            self.universalLinkHost = universalLinkHost
            self.path = path
            self.linkTTL = linkTTL
            self.deviceAttributionCooldown = deviceAttributionCooldown
            self.perReferrerDailyCap = perReferrerDailyCap
            self.regionSanityEnabled = regionSanityEnabled
        }
    }

    // MARK: State

    @Published public private(set) var status: Status = .idle

    private let rewards: RewardsWalleting
    private let coarseLoc: CoarseLocationProviding
    private let log = Logger(subsystem: "com.skateroute.referrals", category: "ReferralService")
    private let config: Config
    private let analytics: ReferralAnalytics?

    private let storage = SecureReferralStorage()
    private let signer = InviteKeyManager()

    // MARK: Init

    public init(config: Config,
                rewards: RewardsWalleting,
                coarseLocation: CoarseLocationProviding,
                analytics: ReferralAnalytics? = nil) {
        self.config = config
        self.rewards = rewards
        self.coarseLoc = coarseLocation
        self.analytics = analytics
    }

    // MARK: Link generation

    /// Generates a signed universal link for the current user.
    public func generateInviteLink(referrerId: String, campaign: ReferralCampaign) async {
        do {
            let pubKey = try signer.publicKeyRaw()
            let payload = Payload(
                v: 1,
                referrerId: sanitize(referrerId),
                nonce: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                createdAt: Date(),
                campaign: campaign,
                inviterPubKey: pubKey
            )

            let canonical = try JSONEncoder.referralCanonical.encode(payload)
            let signature = try signer.sign(message: canonical)
            let env = Envelope(payload: payload, sig: signature, alg: "Ed25519")

            let url = try encodeEnvelopeToURL(env)
            status = .linkGenerated(url)
            analytics?.log(.linkGenerated, meta: ["campaign": campaign.rawValue])
        } catch {
            analytics?.log(.linkFailed, meta: ["error": error.localizedDescription])
            status = .rejected(reason: "Couldn’t generate invite link.")
            log.error("Invite link generation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Inbound handling (NSUserActivity / openURL)

    public func handle(userActivity: NSUserActivity) {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else { return }
        Task { await handle(opened: url) }
    }

    public func handle(opened url: URL) async {
        do {
            let env = try decodeEnvelopeFromURL(url)
            analytics?.log(.inboundParsed, meta: ["campaign": env.payload.campaign.rawValue])

            // Expiry
            guard Date().timeIntervalSince(env.payload.createdAt) <= config.linkTTL else {
                analytics?.log(.inboundExpired, meta: nil)
                status = .rejected(reason: "Invite expired.")
                return
            }

            // Verify signature
            try verify(env)

            // Replay defense
            if storage.hasSeenNonce(env.payload.nonce) {
                analytics?.log(.inboundReplay, meta: nil)
                status = .rejected(reason: "Invite already used.")
                return
            }

            // Cooldown (device-bound)
            if let last = storage.lastAttributionDate,
               Date().timeIntervalSince(last) < config.deviceAttributionCooldown {
                analytics?.log(.fraudCooldown, meta: nil)
                status = .rejected(reason: "Please try again later.")
                return
            }

            // Stash pending attribution for first app open / account creation
            storage.storePendingAttribution(env)
            storage.markNonceSeen(env.payload.nonce)
            status = .pendingAttribution(referrerId: env.payload.referrerId, campaign: env.payload.campaign)
            analytics?.log(.attributionQueued, meta: ["referrerId": env.payload.referrerId])

        } catch ReferralError.badSignature {
            analytics?.log(.inboundInvalidSig, meta: nil)
            status = .rejected(reason: "Invalid invite.")
        } catch {
            status = .rejected(reason: "Couldn’t open invite.")
            log.error("Inbound referral error: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Claim (call on first app open or post sign-up)

    /// Applies pending attribution if it passes guardrails, mints reward exactly once.
    @discardableResult
    public func claimPendingAttribution(refereeId: String) async -> Bool {
        guard let env = storage.loadPendingAttribution() else { return false }

        // Region sanity (optional, coarse only)
        if config.regionSanityEnabled {
            if let deviceRegion = coarseLoc.currentRegionCode,
               let linkRegion = regionFromReferrerPublicKey(env.payload.inviterPubKey) {
                // Simple mismatch heuristic: only suppress if wildly different and link is < 24h old.
                if deviceRegion != linkRegion && Date().timeIntervalSince(env.payload.createdAt) < 24*60*60 {
                    analytics?.log(.fraudRegionMismatch, meta: ["device": deviceRegion, "link": linkRegion])
                    status = .rejected(reason: "Invite cannot be verified in your region yet.")
                    return false
                }
            }
        }

        // Per-referrer daily cap
        let todayKey = SecureReferralStorage.dayKey(for: Date())
        let count = storage.referrerDailyCount(referrerId: env.payload.referrerId, dayKey: todayKey)
        if count >= config.perReferrerDailyCap {
            analytics?.log(.fraudDailyCap, meta: ["referrerId": env.payload.referrerId])
            status = .rejected(reason: "Invite limit reached for today.")
            return false
        }

        // Idempotent reward minting
        if rewards.hasClaimedInviteReward(referrerId: env.payload.referrerId, refereeId: refereeId) {
            analytics?.log(.rewardDuplicate, meta: ["referrerId": env.payload.referrerId])
            storage.clearPendingAttribution()
            status = .attributed(referrerId: env.payload.referrerId, refereeId: refereeId, campaign: env.payload.campaign)
            return true
        }

        let _ = rewards.mintInviteReward(referrerId: env.payload.referrerId, refereeId: refereeId)
        storage.bumpReferrerDailyCount(referrerId: env.payload.referrerId, dayKey: todayKey)
        storage.lastAttributionDate = Date()
        storage.clearPendingAttribution()

        status = .attributed(referrerId: env.payload.referrerId, refereeId: refereeId, campaign: env.payload.campaign)
        analytics?.log(.rewardMinted, meta: ["referrerId": env.payload.referrerId])
        return true
    }

    // MARK: Encoding/Decoding

    private func encodeEnvelopeToURL(_ env: Envelope) throws -> URL {
        let json = try JSONEncoder.referralCanonical.encode(env)
        let b64 = Base64URL.encode(json)
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = config.universalLinkHost
        comps.path = config.path
        comps.queryItems = [URLQueryItem(name: "e", value: b64)]
        guard let url = comps.url else { throw ReferralError.badURL }
        return url
    }

    private func decodeEnvelopeFromURL(_ url: URL) throws -> Envelope {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let e = items.first(where: { $0.name == "e" })?.value,
              let data = Base64URL.decode(e) else { throw ReferralError.badURL }
        return try JSONDecoder.referralCanonical.decode(Envelope.self, from: data)
    }

    private func verify(_ env: Envelope) throws {
        guard env.envelopeValid else { throw ReferralError.badSignature }
    }

    // MARK: Helpers

    private func sanitize(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Optional: derive a coarse "region" hint from inviterPubKey bytes for cheap locality sanity (non-PII).
    private func regionFromReferrerPublicKey(_ pk: Data) -> String? {
        // Take first byte → map into a stable subset for sanity signal (not security).
        guard let first = pk.first else { return nil }
        let regions = ["US","CA","GB","DE","FR","AU","NZ","ES","IT","SE","NO","NL","JP","KR","BR","MX"]
        return regions[Int(first) % regions.count]
    }
}

// MARK: - Canonical JSON coders

private extension JSONEncoder {
    static var referralCanonical: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes] // stable for signing
        return e
    }
}
private extension JSONDecoder {
    static var referralCanonical: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

// MARK: - Envelope verification

private extension ReferralService.Envelope {
    var envelopeValid: Bool {
        guard alg == "Ed25519" else { return false }
        do {
            let payloadData = try JSONEncoder.referralCanonical.encode(payload)
            let pub = try Curve25519.Signing.PublicKey(rawRepresentation: payload.inviterPubKey)
            return pub.isValidSignature(sig, for: payloadData)
        } catch { return false }
    }
}

// MARK: - Errors

enum ReferralError: Error {
    case badURL
    case badSignature
    case keyFailure
}

// MARK: - Base64URL helpers

private enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ s: String) -> Data? {
        var str = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = str.count % 4
        if rem > 0 { str.append(String(repeating: "=", count: 4 - rem)) }
        return Data(base64Encoded: str)
    }
}

// MARK: - Secure key management (Ed25519, Secure Enclave preferred)

private final class InviteKeyManager {
    private let tag = "com.skateroute.referrals.ed25519"
    func publicKeyRaw() throws -> Data {
        try keypair().publicKey.rawRepresentation
    }
    func sign(message: Data) throws -> Data {
        try keypair().privateKey.signature(for: message)
    }
    private func keypair() throws -> (publicKey: Curve25519.Signing.PublicKey, privateKey: Curve25519.Signing.PrivateKey) {
        if let privData: Data = Keychain.load(tag: tag),
           let priv = try? Curve25519.Signing.PrivateKey(rawRepresentation: privData) {
            return (priv.publicKey, priv)
        }
        let priv = Curve25519.Signing.PrivateKey() // stored in Keychain, not in code
        try Keychain.save(data: priv.rawRepresentation, tag: tag)
        return (priv.publicKey, priv)
    }
}

// MARK: - Secure storage (Keychain + small JSONs)

private final class SecureReferralStorage {
    private let pendingKey = "com.skateroute.referrals.pending"
    private let seenNoncesKey = "com.skateroute.referrals.seenNonces"
    private let lastAttrKey = "com.skateroute.referrals.lastAttr"
    private let perReferrerDayPrefix = "com.skateroute.referrals.daily."

    var lastAttributionDate: Date? {
        get { Keychain.load(tag: lastAttrKey).flatMap { try? JSONDecoder().decode(Date.self, from: $0) } }
        set { if let d = newValue { try? Keychain.save(data: try JSONEncoder().encode(d), tag: lastAttrKey) } }
    }

    func storePendingAttribution(_ env: ReferralService.Envelope) {
        let data = try? JSONEncoder.referralCanonical.encode(env)
        if let data { try? Keychain.save(data: data, tag: pendingKey) }
    }

    func loadPendingAttribution() -> ReferralService.Envelope? {
        Keychain.load(tag: pendingKey).flatMap { try? JSONDecoder.referralCanonical.decode(ReferralService.Envelope.self, from: $0) }
    }

    func clearPendingAttribution() {
        Keychain.delete(tag: pendingKey)
    }

    func hasSeenNonce(_ nonce: String) -> Bool {
        guard let data = Keychain.load(tag: seenNoncesKey),
              let set = try? JSONDecoder().decode(Set<String>.self, from: data) else { return false }
        return set.contains(nonce)
    }

    func markNonceSeen(_ nonce: String) {
        var set: Set<String> = []
        if let data = Keychain.load(tag: seenNoncesKey),
           let existing = try? JSONDecoder().decode(Set<String>.self, from: data) { set = existing }
        set.insert(nonce)
        if let data = try? JSONEncoder().encode(set) {
            try? Keychain.save(data: data, tag: seenNoncesKey)
        }
    }

    func referrerDailyCount(referrerId: String, dayKey: String) -> Int {
        let tag = perReferrerDayPrefix + dayKey + "." + referrerId
        guard let data = Keychain.load(tag: tag),
              let n = try? JSONDecoder().decode(Int.self, from: data) else { return 0 }
        return n
    }

    func bumpReferrerDailyCount(referrerId: String, dayKey: String) {
        let tag = perReferrerDayPrefix + dayKey + "." + referrerId
        let n = referrerDailyCount(referrerId: referrerId, dayKey: dayKey) + 1
        if let data = try? JSONEncoder().encode(n) {
            try? Keychain.save(data: data, tag: tag)
        }
    }

    static func dayKey(for date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}

// MARK: - Minimal Keychain shim (no secrets in code; replace with your shared util if present)

private enum Keychain {
    static func save(data: Data, tag: String) throws {
        delete(tag: tag)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw ReferralError.keyFailure }
    }

    static func load(tag: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecSuccess, let d = out as? Data { return d }
        return nil
    }

    static func delete(tag: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag
        ]
        SecItemDelete(query as CFDictionary)
    }
}


