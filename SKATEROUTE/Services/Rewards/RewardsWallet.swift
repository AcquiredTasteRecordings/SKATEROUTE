//Services/Rewards/RewardsWallet.swift

import Foundation

/// App-wide rewards wallet: offline-first, Codable, deterministic.
/// Holds points, badges, lightweight audit trail, daily caps, and streaks.
/// No I/O, no timers. All time passed in via `now:` for testability.
public struct RewardsWallet: Codable, Sendable, Equatable {
    // MARK: Versioning
    public static let modelVersion = 1

    // MARK: Public profile
    public private(set) var points: Int
    public private(set) var lifetimePoints: Int
    public private(set) var earnedBadges: [String]
    public private(set) var lastUpdated: Date
    public private(set) var streakDays: Int // consecutive active days

    // MARK: Governance
    public private(set) var version: Int
    public private(set) var transactions: [RewardTransaction] // ring buffer
    public private(set) var recentDaily: [DailyLedger] // last ~2 weeks for caps

    // MARK: Init
    public init(points: Int = 0,
                lifetimePoints: Int = 0,
                earnedBadges: [String] = [],
                lastUpdated: Date = .init(),
                streakDays: Int = 0,
                version: Int = RewardsWallet.modelVersion,
                transactions: [RewardTransaction] = [],
                recentDaily: [DailyLedger] = []) {
        self.points = max(0, points)
        self.lifetimePoints = max(0, lifetimePoints)
        self.earnedBadges = earnedBadges
        self.lastUpdated = lastUpdated
        self.streakDays = max(0, streakDays)
        self.version = version
        self.transactions = transactions
        self.recentDaily = recentDaily
        _pruneLedgers(now: lastUpdated)
        _pruneTransactions()
    }

    // MARK: Public API

    public enum RewardError: Error, LocalizedError {
        case insufficientPoints
        case dailyCapReached
        case invalidAmount
        public var errorDescription: String? {
            switch self {
            case .insufficientPoints: return "Not enough points to redeem."
            case .dailyCapReached: return "Daily cap reached. Try again tomorrow."
            case .invalidAmount: return "Invalid points amount."
            }
        }
    }

    /// Earn via a typed event. Applies per-event rules, daily caps, and streak updates.
    @discardableResult
    public mutating func earn(_ event: EarnEvent, now: Date = .init()) throws -> RewardTransaction {
        var ledger = _ledger(for: now)
        let dayId = ledger.dayId

        // Compute raw points for event under rules
        let raw = RewardRules.points(for: event)
        guard raw > 0 else { throw RewardError.invalidAmount }

        // Enforce per-event and per-day caps
        if try !_applyCapsPrecheck(event: event, rawPoints: raw, ledger: ledger) {
            throw RewardError.dailyCapReached
        }

        // Update per-event counters in the daily ledger
        ledger.apply(event: event, rawPoints: raw)

        // Final points after caps
        let granted = RewardRules.clampToDailyCaps(event: event, rawPoints: raw, ledger: ledger)

        // Write back ledger and state
        _upsert(ledger)
        let newBalance = _credit(points: granted, now: now)

        // Streak update (only if newly active today)
        _updateStreakIfNeeded(from: lastUpdated, to: now)

        // Audit trail
        let txn = RewardTransaction(
            id: UUID().uuidString,
            date: now,
            delta: granted,
            reason: .earned(event),
            balanceAfter: newBalance,
            meta: event.meta
        )
        _appendTransaction(txn)
        return txn
    }

    /// Redeem points for a product or benefit.
    @discardableResult
    public mutating func redeem(cost: Int, productId: String, now: Date = .init()) throws -> RewardTransaction {
        guard cost > 0 else { throw RewardError.invalidAmount }
        guard points >= cost else { throw RewardError.insufficientPoints }
        points -= cost
        lastUpdated = now
        let txn = RewardTransaction(
            id: UUID().uuidString,
            date: now,
            delta: -cost,
            reason: .redeemed(productId: productId),
            balanceAfter: points,
            meta: ["productId": productId]
        )
        _appendTransaction(txn)
        return txn
    }

    /// Award a badge once. Idempotent.
    public mutating func awardBadge(_ id: String, now: Date = .init()) {
        guard !earnedBadges.contains(id) else { return }
        earnedBadges.append(id)
        lastUpdated = now
        let txn = RewardTransaction(
            id: UUID().uuidString,
            date: now,
            delta: 0,
            reason: .badge(id: id),
            balanceAfter: points,
            meta: ["badgeId": id]
        )
        _appendTransaction(txn)
    }

    /// Hard reset for sign-out or QA only.
    public mutating func reset(now: Date = .init()) {
        points = 0
        lifetimePoints = 0
        earnedBadges.removeAll()
        lastUpdated = now
        streakDays = 0
        transactions.removeAll(keepingCapacity: true)
        recentDaily.removeAll(keepingCapacity: true)
    }

    // MARK: Computed

    public var tier: WalletTier { WalletTier(points: lifetimePoints) }
    public var nextTierProgress: TierProgress { tier.progress(currentLifetime: lifetimePoints) }

    // MARK: Private state helpers

    @discardableResult
    private mutating func _credit(points: Int, now: Date) -> Int {
        guard points > 0 else { return self.points }
        self.points &+= points
        self.lifetimePoints &+= points
        self.lastUpdated = now
        return self.points
    }

    private mutating func _appendTransaction(_ txn: RewardTransaction) {
        transactions.append(txn)
        _pruneTransactions()
    }

    private mutating func _pruneTransactions(max: Int = 200) {
        if transactions.count > max { transactions.removeFirst(transactions.count - max) }
    }

    private mutating func _pruneLedgers(now: Date, keepDays: Int = 16) {
        let cutoff = RewardsWallet.dayId(from: now) - keepDays
        recentDaily.removeAll { $0.dayId < cutoff }
    }

    private mutating func _upsert(_ ledger: DailyLedger) {
        if let idx = recentDaily.firstIndex(where: { $0.dayId == ledger.dayId }) {
            recentDaily[idx] = ledger
        } else {
            recentDaily.append(ledger)
            recentDaily.sort { $0.dayId < $1.dayId }
            _pruneLedgers(now: lastUpdated)
        }
    }

    private func _ledger(for now: Date) -> DailyLedger {
        let id = RewardsWallet.dayId(from: now)
        return recentDaily.last(where: { $0.dayId == id }) ?? DailyLedger(dayId: id)
    }

    private mutating func _updateStreakIfNeeded(from prev: Date, to now: Date) {
        let prevId = RewardsWallet.dayId(from: prev)
        let nowId = RewardsWallet.dayId(from: now)
        if nowId == prevId { return } // same day
        if nowId == prevId + 1 { streakDays &+= 1 } else { streakDays = 1 }
    }

    private func _applyCapsPrecheck(event: EarnEvent, rawPoints: Int, ledger: DailyLedger) throws -> Bool {
        // Global day cap
        if ledger.earnedPoints >= RewardRules.dailyPointCap { return false }
        // Per-event checks
        switch event {
        case .dailyCheckIn:
            return !ledger.checkInClaimed
        case .distanceKm:
            return ledger.distanceKmEarned < RewardRules.distanceDailyKmCap
        case .hazardReport:
            return ledger.hazardReports < RewardRules.hazardReportsDailyCap
        default:
            return true
        }
    }
}

// MARK: - Types

public enum WalletTier: String, Codable, CaseIterable, Sendable {
    case bronze, silver, gold, platinum

    public init(points: Int) {
        switch points {
        case ..<500: self = .bronze
        case 500..<2_000: self = .silver
        case 2_000..<5_000: self = .gold
        default: self = .platinum
        }
    }

    public struct TierProgress: Codable, Sendable, Equatable {
        public let current: Int
        public let nextThreshold: Int
        public let remaining: Int
        public let fraction: Double
    }

    public func progress(currentLifetime: Int) -> TierProgress {
        let next: Int
        switch self {
        case .bronze: next = 500
        case .silver: next = 2_000
        case .gold: next = 5_000
        case .platinum: next = currentLifetime // top tier; treat as complete
        }
        let remaining = max(0, next - currentLifetime)
        let fraction = next == 0 ? 1 : min(1, Double(currentLifetime) / Double(next))
        return TierProgress(current: currentLifetime, nextThreshold: next, remaining: remaining, fraction: fraction)
    }
}

public struct RewardTransaction: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let date: Date
    public let delta: Int
    public let reason: Reason
    public let balanceAfter: Int
    public let meta: [String: String]?

    public enum Reason: Codable, Sendable, Equatable {
        case earned(EarnEvent)
        case redeemed(productId: String)
        case badge(id: String)
    }
}

public enum EarnEvent: Codable, Sendable, Equatable {
    case distanceKm(Double)              // value: km
    case hazardReport(quality: Int)      // 1..3
    case referralAccepted
    case dailyCheckIn
    case challengeCompleted(difficulty: Int) // 1..3
    case spotAdded
    case videoShared

    fileprivate var meta: [String: String] {
        switch self {
        case .distanceKm(let km): return ["km": String(km)]
        case .hazardReport(let q): return ["quality": String(q)]
        case .challengeCompleted(let d): return ["difficulty": String(d)]
        case .referralAccepted: return ["referral": "accepted"]
        case .dailyCheckIn: return ["checkIn": "1"]
        case .spotAdded: return ["spot": "added"]
        case .videoShared: return ["video": "shared"]
        }
    }
}

public struct DailyLedger: Codable, Sendable, Equatable {
    public let dayId: Int // YYYYMMDD
    public var earnedPoints: Int = 0
    public var hazardReports: Int = 0
    public var checkInClaimed: Bool = false
    public var distanceKmEarned: Double = 0

    public init(dayId: Int) { self.dayId = dayId }

    public mutating func apply(event: EarnEvent, rawPoints: Int) {
        earnedPoints &+= rawPoints
        switch event {
        case .dailyCheckIn: checkInClaimed = true
        case .hazardReport: hazardReports &+= 1
        case .distanceKm(let km): distanceKmEarned += km
        default: break
        }
    }
}

public enum RewardRules {
    // Global/day caps
    public static let dailyPointCap = 2_000
    public static let distanceDailyKmCap: Double = 25
    public static let hazardReportsDailyCap = 10

    // Base weights
    private static let pointsPerKm = 5
    private static let hazardBase = 20 // per report, scaled by quality
    private static let referralBonus = 250
    private static let dailyCheckInBonus = 15
    private static let challengeBase = 150 // scaled by difficulty
    private static let spotAddedBonus = 50
    private static let videoSharedBonus = 10

    public static func points(for event: EarnEvent) -> Int {
        switch event {
        case .distanceKm(let km):
            let kmClamped = max(0, min(km, distanceDailyKmCap))
            return Int(kmClamped.rounded(.down)) * pointsPerKm
        case .hazardReport(let quality):
            let q = max(1, min(quality, 3))
            return hazardBase * q
        case .referralAccepted:
            return referralBonus
        case .dailyCheckIn:
            return dailyCheckInBonus
        case .challengeCompleted(let difficulty):
            let d = max(1, min(difficulty, 3))
            return challengeBase * d
        case .spotAdded:
            return spotAddedBonus
        case .videoShared:
            return videoSharedBonus
        }
    }

    /// Final clamp after updating the ledger to respect remaining caps.
    public static func clampToDailyCaps(event: EarnEvent, rawPoints: Int, ledger: DailyLedger) -> Int {
        var allowed = rawPoints
        // Global remaining
        let remainingGlobal = max(0, dailyPointCap - ledger.earnedPoints)
        allowed = min(allowed, remainingGlobal)
        // Event-specific remaining
        switch event {
        case .distanceKm:
            // Points already computed with km clamp, nothing extra here
            break
        case .hazardReport:
            if ledger.hazardReports > hazardReportsDailyCap { allowed = 0 }
        default:
            break
        }
        return max(0, allowed)
    }
}

// MARK: - Utilities

extension RewardsWallet {
    public static func dayId(from date: Date, calendar: Calendar = .current) -> Int {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        let y = (comps.year ?? 1970)
        let m = (comps.month ?? 1)
        let d = (comps.day ?? 1)
        return y * 10_000 + m * 100 + d
    }
}


