// Services/Rewards/RewardsWallet.swift
// Local wallet for earned badges and partner rewards (coupons) with secure storage.
// - Badges: idempotent minting, optional stacking groups.
// - Coupons: single-claim (or limited-use) guarantees, QR payloads for offline verification, expiry handling.
// - Storage: tamper-evident JSON (HMAC-SHA256) + device-bound symmetric key in Keychain.
// - Publishers for UI overlays and reward views. No PII, no tracking.

import Foundation
import Combine
import CryptoKit
import CoreImage
import CoreImage.CIFilterBuiltins
import os.log

// MARK: - Public models

public struct Badge: Codable, Hashable, Identifiable {
    public let id: String                 // globally unique (e.g., "week_distance_2025W45")
    public let name: String               // display label
    public let earnedAt: Date
    public let metadata: [String: String] // small, safe strings only (e.g., meters, weekStart timestamp)
    public let stackingGroup: String?     // e.g., "streak_distance" (highest tier wins in stacking views)
    public let tier: Int?                 // optional tier for stacking (e.g., 3, 5, 10)
    public var displaySortKey: String { "\(stackingGroup ?? id):\(tier ?? 0):\(id)" }
    public init(id: String, name: String, earnedAt: Date, metadata: [String: String], stackingGroup: String? = nil, tier: Int? = nil) {
        self.id = id; self.name = name; self.earnedAt = earnedAt; self.metadata = metadata; self.stackingGroup = stackingGroup; self.tier = tier
    }
}

public enum CouponState: String, Codable, Equatable { case active, redeemed, expired }

public struct PartnerCoupon: Codable, Hashable, Identifiable {
    public let id: String                  // unique coupon id
    public let partnerId: String           // business id
    public let title: String               // short line for UI card
    public let details: String?            // optional small print
    public let qrPayload: String           // opaque string for offline verification (signed server-side ideally)
    public let issuedAt: Date
    public let expiresAt: Date?
    public var redemptionCount: Int        // local accounting
    public var maxRedemptions: Int         // default 1
    public var lastRedeemedAt: Date?
    public var state: CouponState

    public var isExpired: Bool {
        if let e = expiresAt { return Date() >= e } else { return false }
    }

    public init(id: String, partnerId: String, title: String, details: String?, qrPayload: String, issuedAt: Date, expiresAt: Date?, maxRedemptions: Int = 1) {
        self.id = id; self.partnerId = partnerId; self.title = title; self.details = details; self.qrPayload = qrPayload
        self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.redemptionCount = 0; self.maxRedemptions = maxRedemptions
        self.lastRedeemedAt = nil; self.state = .active
    }
}

// MARK: - Snapshot (immutable view)

public struct RewardsSnapshot: Sendable, Equatable {
    public let badges: [Badge]            // newest first
    public let coupons: [PartnerCoupon]   // active first, then redeemed, then expired
}

// MARK: - DI seams

/// Minimal API used by producers (e.g., ChallengeEngine) and feature UIs.
public protocol RewardsWalleting {
    func earnBadge(id: String, name: String, metadata: [String: String]) async
}

/// QR code rendering target (UIKit-free; render to PNG Data).
public protocol QRRendering {
    func png(from string: String, side: CGFloat, quietZone: Int) -> Data?
}

public final class CoreImageQRRenderer: QRRendering {
    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()
    public init() {}
    public func png(from string: String, side: CGFloat, quietZone: Int = 4) -> Data? {
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let ciImage = filter.outputImage else { return nil }
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: side / ciImage.extent.size.width, y: side / ciImage.extent.size.height))
            .transformed(by: CGAffineTransform(translationX: CGFloat(quietZone), y: CGFloat(quietZone)))
        let bounds = CGRect(x: 0, y: 0, width: side + CGFloat(quietZone * 2), height: side + CGFloat(quietZone * 2))
        guard let cg = context.createCGImage(scaled, from: bounds) else { return nil }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("qr-\(UUID().uuidString).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, kUTTypePNG, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return try? Data(contentsOf: url)
    }
}

// MARK: - Wallet

@MainActor
public final class RewardsWallet: ObservableObject, RewardsWalleting {

    public enum State: Equatable { case idle, ready, error(String) }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var snapshot: RewardsSnapshot

    public var snapshotPublisher: AnyPublisher<RewardsSnapshot, Never> { $snapshot.eraseToAnyPublisher() }

    // DI
    private let qr: QRRendering
    private let log = Logger(subsystem: "com.skateroute", category: "RewardsWallet")

    // Persistence
    private let fm = FileManager.default
    private let storeURL: URL
    private let keychainKeyName = "rewards.wallet.hmac.key"

    // In-memory mutable store
    private var badges: [Badge] = []
    private var coupons: [PartnerCoupon] = []

    // MARK: Init

    public init(qrRenderer: QRRendering = CoreImageQRRenderer()) {
        self.qr = qrRenderer

        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Rewards", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("wallet.json")

        // Load or bootstrap
        if let (b, c) = loadSecure() {
            self.badges = b
            self.coupons = c
        }
        self.snapshot = RewardsSnapshot(badges: RewardsWallet.sortBadges(self.badges),
                                        coupons: RewardsWallet.sortCoupons(self.coupons))
        self.state = .ready

        // Opportunistic cleanup
        cleanupExpiredCoupons()
    }

    // MARK: Public API — Badges

    /// Idempotent: same id is ignored after first award. Stacking rules auto-calc based on metadata.
    public func earnBadge(id: String, name: String, metadata: [String: String]) async {
        guard !badges.contains(where: { $0.id == id }) else { return }
        let (group, tier) = RewardsWallet.stackingInfo(for: id, metadata: metadata)
        let badge = Badge(id: id, name: name, earnedAt: Date(), metadata: metadata, stackingGroup: group, tier: tier)
        badges.append(badge)
        persist()
        publish()
    }

    public func hasBadge(_ id: String) -> Bool { badges.contains(where: { $0.id == id }) }

    public func badgesGroupedForStacking() -> [String: [Badge]] {
        Dictionary(grouping: badges, by: { $0.stackingGroup ?? $0.id })
            .mapValues { $0.sorted { (a, b) in
                if let ta = a.tier, let tb = b.tier, ta != tb { return ta > tb }
                return a.earnedAt > b.earnedAt
            }}
    }

    // MARK: Public API — Coupons

    /// Issue (or upsert) a coupon; if already present, refresh details and expiry but preserve redemption count.
    public func issueCoupon(_ c: PartnerCoupon) {
        if let idx = coupons.firstIndex(where: { $0.id == c.id }) {
            var cur = coupons[idx]
            cur.title = c.title
            cur.details = c.details
            cur.qrPayload = c.qrPayload
            cur.expiresAt = c.expiresAt
            cur.maxRedemptions = c.maxRedemptions
            // state remains (if already redeemed, keep it)
            coupons[idx] = cur
        } else {
            coupons.append(c)
        }
        persist(); publish()
    }

    /// Attempt redemption with single-claim guarantees and expiry enforcement.
    /// Returns true if redemption applied; false if already redeemed or expired or over cap.
    @discardableResult
    public func redeemCoupon(id: String) -> Bool {
        guard let idx = coupons.firstIndex(where: { $0.id == id }) else { return false }
        var c = coupons[idx]
        // Expiry gate
        if c.isExpired {
            c.state = .expired
            coupons[idx] = c
            persist(); publish()
            return false
        }
        // Max cap gate
        guard c.redemptionCount < c.maxRedemptions else { return false }
        // Commit redemption
        c.redemptionCount += 1
        c.lastRedeemedAt = Date()
        if c.redemptionCount >= c.maxRedemptions { c.state = .redeemed }
        coupons[idx] = c
        persist(); publish()
        return true
    }

    /// QR PNG payload for UI (Share/Wallet screens). Returns nil if coupon not found.
    public func couponQRPNG(id: String, side: CGFloat = 260, quietZone: Int = 4) -> Data? {
        guard let c = coupons.first(where: { $0.id == id }) else { return nil }
        return qr.png(from: c.qrPayload, side: side, quietZone: quietZone)
    }

    /// Remove expired coupons from the active list (keeps redeemed for 30 days for receipts).
    public func cleanupExpiredCoupons(retainRedeemedDays: Int = 30) {
        let cutoff = Date().addingTimeInterval(TimeInterval(-retainRedeemedDays * 86_400))
        coupons = coupons.filter { cp in
            switch cp.state {
            case .active:
                // Update state if now expired
                if cp.isExpired { return false } else { return true }
            case .redeemed:
                // Keep redeemed until cutoff
                return (cp.lastRedeemedAt ?? cp.issuedAt) > cutoff
            case .expired:
                // Drop already-marked expired beyond retention
                return (cp.expiresAt ?? cp.issuedAt) > cutoff
            }
        }
        persist(); publish()
    }

    // MARK: Private — publish/persist

    private func publish() {
        snapshot = RewardsSnapshot(badges: RewardsWallet.sortBadges(badges),
                                   coupons: RewardsWallet.sortCoupons(coupons))
    }

    private static func sortBadges(_ list: [Badge]) -> [Badge] {
        list.sorted { a, b in
            if a.stackingGroup == b.stackingGroup {
                if let ta = a.tier, let tb = b.tier, ta != tb { return ta > tb }
            }
            return a.earnedAt > b.earnedAt
        }
    }

    private static func sortCoupons(_ list: [PartnerCoupon]) -> [PartnerCoupon] {
        list.sorted { a, b in
            if a.state != b.state {
                // active → redeemed → expired
                return order(a.state) < order(b.state)
            }
            // Within state, sooner expiry first; then most recently issued
            switch (a.expiresAt, b.expiresAt) {
            case (.some(let da), .some(let db)): if da != db { return da < db }
            case (.some, .none): return true
            case (.none, .some): return false
            default: break
            }
            return a.issuedAt > b.issuedAt
        }
        func order(_ s: CouponState) -> Int {
            switch s { case .active: return 0; case .redeemed: return 1; case .expired: return 2 }
        }
    }

    // MARK: Secure persistence (JSON + HMAC)

    private struct DiskPayload: Codable {
        let badges: [Badge]
        let coupons: [PartnerCoupon]
        let hmac: String   // hex string of HMAC-SHA256 over canonical JSON {badges,coupons}
    }

    private func persist() {
        let content: [String: Any] = [
            "badges": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(badges)),
            "coupons": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(coupons))
        ]
        guard let canonical = try? JSONSerialization.data(withJSONObject: content, options: [.sortedKeys]) else { return }
        guard let key = loadOrCreateKey() else { return }
        let hmac = HMAC<SHA256>.authenticationCode(for: canonical, using: SymmetricKey(data: key))
        let hex = Data(hmac).map { String(format: "%02x", $0) }.joined()
        let payload = DiskPayload(badges: badges, coupons: coupons, hmac: hex)
        guard let out = try? JSONEncoder().encode(payload) else { return }
        do { try out.write(to: storeURL, options: .atomic) } catch {
            log.error("Rewards wallet persist failed: \(error.localizedDescription, privacy: .public)")
            state = .error("Couldn’t save rewards")
        }
    }

    private func loadSecure() -> ([Badge], [PartnerCoupon])? {
        guard let data = try? Data(contentsOf: storeURL),
              let payload = try? JSONDecoder().decode(DiskPayload.self, from: data),
              let key = loadOrCreateKey() else { return nil }

        // Recreate canonical content for verification
        let content: [String: Any] = [
            "badges": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(payload.badges)),
            "coupons": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(payload.coupons))
        ]
        guard let canonical = try? JSONSerialization.data(withJSONObject: content, options: [.sortedKeys]) else { return nil }
        guard let hmacData = Data(hexString: payload.hmac) else { return nil }
        let ok = HMAC<SHA256>.isValidAuthenticationCode(hmacData, authenticating: canonical, using: SymmetricKey(data: key))
        if !ok {
            log.error("Rewards wallet integrity check failed; starting fresh.", privacy: .public)
            return nil
        }
        return (payload.badges, payload.coupons)
    }

    // MARK: Keychain

    private func loadOrCreateKey() -> Data? {
        if let existing = Keychain.read(key: keychainKeyName) { return existing }
        var key = Data(count: 32)
        _ = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard Keychain.save(key: keychainKeyName, data: key) else { return nil }
        return key
    }

    // MARK: Stacking rules

    /// Heuristics: if id looks like "streak_distance_10" -> group "streak_distance", tier 10.
    private static func stackingInfo(for id: String, metadata: [String: String]) -> (group: String?, tier: Int?) {
        if let range = id.range(of: #"_\d+$"#, options: .regularExpression) {
            let prefix = String(id[id.startIndex..<range.lowerBound])
            let numString = String(id[range]).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            if let n = Int(numString) {
                return (prefix, n)
            }
        }
        if let group = metadata["group"], let tierStr = metadata["tier"], let n = Int(tierStr) {
            return (group, n)
        }
        return (nil, nil)
    }
}

// MARK: - Tiny Keychain helper (generic password, app-scoped)

fileprivate enum Keychain {
    static func save(key: String, data: Data) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.skateroute.rewards",
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(q as CFDictionary)
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func read(key: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.skateroute.rewards",
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess else { return nil }
        return out as? Data
    }
}

// MARK: - Utilities

fileprivate extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var idx = hexString.startIndex
        for _ in 0..<len {
            let next = hexString.index(idx, offsetBy: 2)
            guard next <= hexString.endIndex else { return nil }
            let byteStr = hexString[idx..<next]
            guard let b = UInt8(byteStr, radix: 16) else { return nil }
            data.append(b)
            idx = next
        }
        self = data
    }
}

// MARK: - DEBUG Fakes (unit tests)

#if DEBUG
public final class RewardsWalletFake: RewardsWalleting {
    public private(set) var earned: Set<String> = []
    public init() {}
    public func earnBadge(id: String, name: String, metadata: [String : String]) async { earned.insert(id) }
}
#endif

// MARK: - Test plan (you should implement)
//
// • Single-claim guarantees:
//    - Issue coupon with maxRedemptions=1 → redeem returns true once, then false; state transitions to .redeemed.
//    - Issue coupon with maxRedemptions=3 → redeem thrice true, fourth false.
//
// • Expired coupon UI:
//    - Issue coupon with expiresAt in the past → redeemCoupon returns false; state flips to .expired and sorted into the right bucket.
//    - cleanupExpiredCoupons() drops expired/old redeemed based on retention.
//
// • Badge stacking rules:
//    - earnBadge("streak_distance_3"), then "streak_distance_5" → both present; grouped sorting shows tier 5 first.
//    - earnBadge("week_distance_2025W45") twice → only first is stored (idempotent).
//
// • Tamper-evident persistence:
//    - Persist, then flip one byte in wallet.json → next init fails verification and starts fresh (log entry).
//
// • QR rendering:
//    - couponQRPNG returns non-nil PNG Data; size matches expectations (roughly side+quiet zone).
//
// • Concurrency/idempotency:
//    - Call earnBadge concurrently with same id (simulate via TaskGroup) → still one badge (protect via contains check + single-threaded @MainActor writes).
//
// Integration wiring:
//  - Register `RewardsWallet` in AppDI as a singleton; pass it into ChallengeEngine (satisfies RewardsWalleting).
//  - Features/Rewards/RewardsWalletView binds to `snapshotPublisher` to render earned badges and coupons.
//  - For coupon verification flow, partners scan the QR payload; verification is offline-first (payload should be a signed token from PartnerAPI in future).
