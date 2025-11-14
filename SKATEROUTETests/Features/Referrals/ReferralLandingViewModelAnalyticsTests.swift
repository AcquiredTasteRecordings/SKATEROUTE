import XCTest
@testable import SKATEROUTE

@MainActor
final class ReferralLandingViewModelAnalyticsTests: XCTestCase {

    func testJoinChallengeViaReferralEmitsAnalytics() async throws {
        let resolver = ReferralResolverStub()
        let rewards = RewardsStub()
        let challenges = ChallengeJoinerStub()
        let analytics = ReferralAnalyticsLogger()
        let vm = ReferralLandingViewModel(token: "token",
                                          resolver: resolver,
                                          rewards: rewards,
                                          challenges: challenges,
                                          analytics: analytics)

        await vm.resolve()
        try await eventually(timeout: 0.5) { vm.attribution != nil }

        vm.primaryAction()

        try await eventually(timeout: 0.5) {
            analytics.events.contains(where: { $0.name == "challenge_join_result" })
        }

        let attempt = analytics.events.first(where: { $0.name == "challenge_join_attempt" })
        XCTAssertEqual(attempt?.params["challenge_id"], .string("fall_jam"))
        XCTAssertEqual(attempt?.params["source"], .string("referral"))

        let result = analytics.events.first(where: { $0.name == "challenge_join_result" })
        XCTAssertEqual(result?.params["result"], .string("joined"))
        XCTAssertEqual(result?.params["source"], .string("referral"))
    }

    func testJoinFailureLogsFailedResult() async throws {
        let resolver = ReferralResolverStub()
        let rewards = RewardsStub()
        let challenges = ChallengeJoinerStub()
        challenges.shouldThrow = true
        let analytics = ReferralAnalyticsLogger()
        let vm = ReferralLandingViewModel(token: "token",
                                          resolver: resolver,
                                          rewards: rewards,
                                          challenges: challenges,
                                          analytics: analytics)

        await vm.resolve()
        try await eventually(timeout: 0.5) { vm.attribution != nil }

        vm.primaryAction()

        try await eventually(timeout: 0.5) {
            analytics.events.contains(where: { event in
                event.name == "challenge_join_result" && event.params["result"] == .string("failed")
            })
        }
    }
}

// MARK: - Stubs

private final class ReferralResolverStub: ReferralResolving {
    var resolveResult: ReferralAttribution
    var confirmResult: ReferralAttribution
    var shouldThrowResolve = false
    var shouldThrowConfirm = false

    init() {
        let pending = ReferralAttribution(token: "token",
                                          campaign: "fall_jam",
                                          referrerDisplayName: "Alex",
                                          previewRewardTitle: nil,
                                          status: .pending,
                                          isEligibleForReward: false,
                                          isEligibleForChallenge: true)
        self.resolveResult = pending
        self.confirmResult = ReferralAttribution(token: "token",
                                                 campaign: "fall_jam",
                                                 referrerDisplayName: "Alex",
                                                 previewRewardTitle: nil,
                                                 status: .credited,
                                                 isEligibleForReward: false,
                                                 isEligibleForChallenge: true)
    }

    func resolve(token: String) async throws -> ReferralAttribution {
        if shouldThrowResolve { throw StubError.resolve }
        return resolveResult
    }

    func confirmAttribution(token: String) async throws -> ReferralAttribution {
        if shouldThrowConfirm { throw StubError.confirm }
        return confirmResult
    }
}

private final class RewardsStub: RewardsWalletServing {
    func claimReferralReward(token: String) async throws -> RewardClaimResult { .alreadyClaimed }
}

private final class ChallengeJoinerStub: ChallengeJoining {
    var shouldThrow = false
    var joinResult = true

    func joinChallenge(campaignId: String) async throws -> Bool {
        if shouldThrow { throw StubError.join }
        return joinResult
    }
}

private enum StubError: Error {
    case resolve
    case confirm
    case join
}

// MARK: - Shared helpers

@MainActor
private final class ReferralAnalyticsLogger: AnalyticsLogging {
    private let spanDelegate = AnalyticsLogger()
    var events: [AnalyticsEvent] = []

    func updateConfig(_ config: AnalyticsLogger.Config) {}

    func log(_ event: AnalyticsEvent) {
        events.append(event)
    }

    func beginSpan(_ span: AnalyticsSpan) -> AnalyticsSpanHandle { spanDelegate.beginSpan(span) }

    func endSpan(_ handle: AnalyticsSpanHandle) { spanDelegate.endSpan(handle) }
}

private func eventually(timeout: TimeInterval, condition: @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("Condition not met in time")
    throw WaitError.timeout
}

private enum WaitError: Error { case timeout }
