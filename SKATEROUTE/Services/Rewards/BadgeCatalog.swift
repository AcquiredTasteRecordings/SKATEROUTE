//  Services/Rewards/BadgeCatalog.swift
//  SKATEROUTE
//
//  Central registry for all badges + evaluation logic.
//  Pure, deterministic, and tightly integrated with RewardsWallet.
//

import Foundation

// MARK: - Public types

public enum BadgeCategory: String, Codable, CaseIterable, Sendable {
    case progression    // Distance, lifetime points, tiers
    case safety         // Hazard reports, safe routing
    case community      // Referrals, spot contributions, sharing
    case streak         // Daily streaks / consistency
    case special        // Time-limited, founder, event-based
}

public struct BadgeDefinition: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let shortDescription: String
    public let longDescription: String?
    public let category: BadgeCategory
    public let iconName: String       // Name in Resources/Badges or SF Symbol
    public let pointsReward: Int      // One-time bonus when first unlocked
    public let sortOrder: Int
    public let isSecret: Bool         // Hide until unlocked
    public let isRepeatable: Bool     // e.g. weekly challenges

    public init(
        id: String,
        name: String,
        shortDescription: String,
        longDescription: String? = nil,
        category: BadgeCategory,
        iconName: String,
        pointsReward: Int = 0,
        sortOrder: Int,
        isSecret: Bool = false,
        isRepeatable: Bool = false
    ) {
        self.id = id
        self.name = name
        self.shortDescription = shortDescription
        self.longDescription = longDescription
        self.category = category
        self.iconName = iconName
        self.pointsReward = max(0, pointsReward)
        self.sortOrder = sortOrder
        self.isSecret = isSecret
        self.isRepeatable = isRepeatable
    }
}

public struct BadgeStatus: Hashable, Sendable {
    public let definition: BadgeDefinition
    public let isUnlocked: Bool
    /// Progress from 0.0 to 1.0 towards the next unlock.
    public let progress: Double
    /// Current numeric value used for the condition (km, count, etc.).
    public let currentValue: Double
    /// Target value for the unlock condition.
    public let targetValue: Double

    public init(
        definition: BadgeDefinition,
        isUnlocked: Bool,
        progress: Double,
        currentValue: Double,
        targetValue: Double
    ) {
        self.definition = definition
        self.isUnlocked = isUnlocked
        self.progress = max(0, min(1, progress))
        self.currentValue = max(0, currentValue)
        self.targetValue = max(0, targetValue)
    }
}

/// Additional metrics required for badge evaluation beyond RewardsWallet.
public protocol BadgeEvaluationContext {
    var totalDistanceKm: Double { get }
    var totalHazardReports: Int { get }
    var totalSpotsAdded: Int { get }
    var totalReferralsAccepted: Int { get }
    var totalVideosShared: Int { get }
    var totalChallengesCompleted: Int { get }
}

// MARK: - Catalog

public enum BadgeCatalog: Sendable {

    // Canonical list of badges. Keep IDs stable and never reuse.
    public static let all: [BadgeDefinition] = [
        // PROGRESSION
        BadgeDefinition(
            id: "km_010",
            name: "First Push",
            shortDescription: "Skate your first 10 km with SkateRoute.",
            category: .progression,
            iconName: "badge_km_010",
            pointsReward: 50,
            sortOrder: 10
        ),
        BadgeDefinition(
            id: "km_100",
            name: "Street Explorer",
            shortDescription: "Hit 100 km total on your board.",
            category: .progression,
            iconName: "badge_km_100",
            pointsReward: 150,
            sortOrder: 20
        ),
        BadgeDefinition(
            id: "km_500",
            name: "City Circuit",
            shortDescription: "Rack up 500 km of sessions.",
            category: .progression,
            iconName: "badge_km_500",
            pointsReward: 300,
            sortOrder: 30
        ),
        BadgeDefinition(
            id: "points_2000",
            name: "Level Up",
            shortDescription: "Earn 2,000 lifetime points.",
            category: .progression,
            iconName: "badge_points_2000",
            pointsReward: 200,
            sortOrder: 40
        ),

        // SAFETY
        BadgeDefinition(
            id: "hazard_010",
            name: "Local Scout",
            shortDescription: "Report 10 hazards to keep routes safe.",
            category: .safety,
            iconName: "badge_hazard_010",
            pointsReward: 75,
            sortOrder: 100
        ),
        BadgeDefinition(
            id: "hazard_050",
            name: "Safety Marshal",
            shortDescription: "Report 50 hazards across the city.",
            category: .safety,
            iconName: "badge_hazard_050",
            pointsReward: 200,
            sortOrder: 110
        ),

        // COMMUNITY
        BadgeDefinition(
            id: "referral_001",
            name: "Crew Starter",
            shortDescription: "Bring one friend into SkateRoute.",
            category: .community,
            iconName: "badge_referral_001",
            pointsReward: 100,
            sortOrder: 200
        ),
        BadgeDefinition(
            id: "referral_005",
            name: "Squad Leader",
            shortDescription: "Get 5 friends riding with you.",
            category: .community,
            iconName: "badge_referral_005",
            pointsReward: 300,
            sortOrder: 210
        ),
        BadgeDefinition(
            id: "spot_005",
            name: "Spot Finder",
            shortDescription: "Add 5 legit skate spots.",
            category: .community,
            iconName: "badge_spot_005",
            pointsReward: 150,
            sortOrder: 220
        ),
        BadgeDefinition(
            id: "video_010",
            name: "Clip Dropper",
            shortDescription: "Share 10 session clips.",
            category: .community,
            iconName: "badge_video_010",
            pointsReward: 150,
            sortOrder: 230
        ),

        // STREAK
        BadgeDefinition(
            id: "streak_007",
            name: "Week Warrior",
            shortDescription: "Skate 7 days in a row.",
            category: .streak,
            iconName: "badge_streak_007",
            pointsReward: 200,
            sortOrder: 300
        ),
        BadgeDefinition(
            id: "streak_030",
            name: "Die Hard",
            shortDescription: "Keep a 30-day streak alive.",
            category: .streak,
            iconName: "badge_streak_030",
            pointsReward: 500,
            sortOrder: 310
        ),

        // SPECIAL / SECRET
        BadgeDefinition(
            id: "founder_001",
            name: "Founding Skater",
            shortDescription: "Early adopter of SkateRoute.",
            longDescription: "You were part of the early crew that shaped SkateRoute. Respect.",
            category: .special,
            iconName: "badge_founder_001",
            pointsReward: 500,
            sortOrder: 900,
            isSecret: false,
            isRepeatable: false
        )
    ]

    public static let byID: [String: BadgeDefinition] = {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }()

    /// Compute the status for a specific badge id.
    public static func status(
        for id: String,
        wallet: RewardsWallet,
        context: BadgeEvaluationContext
    ) -> BadgeStatus? {
        guard let def = byID[id] else { return nil }
        return evaluate(definition: def, wallet: wallet, context: context)
    }

    /// Evaluate all badges for the current user.
    public static func evaluateAll(
        wallet: RewardsWallet,
        context: BadgeEvaluationContext
    ) -> [BadgeStatus] {
        all.compactMap { evaluate(definition: $0, wallet: wallet, context: context) }
            .sorted { $0.definition.sortOrder < $1.definition.sortOrder }
    }

    // MARK: - Core evaluation

    private static func evaluate(
        definition: BadgeDefinition,
        wallet: RewardsWallet,
        context: BadgeEvaluationContext
    ) -> BadgeStatus {
        let alreadyUnlocked = wallet.earnedBadges.contains(definition.id)

        // Map each badge id to a numeric metric + target.
        let (current, target): (Double, Double) = {
            switch definition.id {

            // PROGRESSION
            case "km_010":   return (context.totalDistanceKm, 10)
            case "km_100":   return (context.totalDistanceKm, 100)
            case "km_500":   return (context.totalDistanceKm, 500)
            case "points_2000": return (Double(wallet.lifetimePoints), 2_000)

            // SAFETY
            case "hazard_010": return (Double(context.totalHazardReports), 10)
            case "hazard_050": return (Double(context.totalHazardReports), 50)

            // COMMUNITY
            case "referral_001": return (Double(context.totalReferralsAccepted), 1)
            case "referral_005": return (Double(context.totalReferralsAccepted), 5)
            case "spot_005":     return (Double(context.totalSpotsAdded), 5)
            case "video_010":    return (Double(context.totalVideosShared), 10)

            // STREAK
            case "streak_007": return (Double(wallet.streakDays), 7)
            case "streak_030": return (Double(wallet.streakDays), 30)

            // SPECIAL
            case "founder_001":
                // Founders are flagged by the app via awardBadge("founder_001") once per account.
                return (alreadyUnlocked ? 1 : 0, 1)

            default:
                // Unknown badge id: treat as locked with zero progress, but don't crash.
                return (0, 1)
            }
        }()

        let unlocked = alreadyUnlocked || current >= target
        let progress = target > 0 ? min(1, current / target) : (unlocked ? 1 : 0)

        return BadgeStatus(
            definition: definition,
            isUnlocked: unlocked,
            progress: progress,
            currentValue: current,
            targetValue: target
        )
    }
}


