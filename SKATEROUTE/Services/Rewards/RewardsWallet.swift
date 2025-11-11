import Foundation

public struct RewardsWallet: Codable, Sendable, Equatable {
    public private(set) var points: Int
    public private(set) var earnedBadges: [String]
    public private(set) var lastUpdated: Date

    public init(points: Int = 0, earnedBadges: [String] = [], lastUpdated: Date = .init()) {
        self.points = max(0, points)
        self.earnedBadges = earnedBadges
        self.lastUpdated = lastUpdated
    }

    public enum RewardError: Error, LocalizedError {
        case insufficientPoints
        public var errorDescription: String? { "Not enough points to redeem." }
    }

    @discardableResult
    public mutating func credit(points: Int) -> Int {
        guard points > 0 else { return self.points }
        self.points += points
        self.lastUpdated = .init()
        return self.points
    }

    public mutating func debit(points: Int) throws {
        guard points >= 0 else { return }
        guard self.points >= points else { throw RewardError.insufficientPoints }
        self.points -= points
        self.lastUpdated = .init()
    }

    public mutating func awardBadge(_ id: String) {
        guard !earnedBadges.contains(id) else { return }
        earnedBadges.append(id)
        lastUpdated = .init()
    }

    public mutating func reset() {
        points = 0
        earnedBadges.removeAll()
        lastUpdated = .init()
    }
}
