import XCTest
import Combine
@testable import SKATEROUTE

@MainActor
final class ChallengesViewModelAnalyticsTests: XCTestCase {

    func testJoinEmitsAnalyticsEvents() async throws {
        let challenge = Self.sampleChallenge(isJoined: false)
        let reader = ChallengeReaderStub(initial: [challenge])
        let actor = ChallengeActorStub()
        let analytics = ChallengesAnalyticsLogger()
        let vm = ChallengesViewModel(reader: reader, actor: actor, analytics: analytics)

        try await eventually(timeout: 0.5) {
            vm.summaries.count == 1
        }

        vm.join(vm.summaries[0])

        try await eventually(timeout: 0.5) {
            analytics.events.contains(where: { $0.name == "challenge_join_result" })
        }

        let attempt = analytics.events.first(where: { $0.name == "challenge_join_attempt" })
        XCTAssertNotNil(attempt)
        XCTAssertEqual(attempt?.category, .challenges)
        XCTAssertEqual(attempt?.params["challenge_id"], .string(challenge.id))

        let result = analytics.events.first(where: { $0.name == "challenge_join_result" })
        XCTAssertEqual(result?.params["result"], .string("joined"))
    }

    func testJoinFailureLogsFailedResult() async throws {
        let challenge = Self.sampleChallenge(isJoined: false)
        let reader = ChallengeReaderStub(initial: [challenge])
        let actor = ChallengeActorStub()
        actor.shouldThrowJoin = true
        let analytics = ChallengesAnalyticsLogger()
        let vm = ChallengesViewModel(reader: reader, actor: actor, analytics: analytics)

        try await eventually(timeout: 0.5) {
            vm.summaries.count == 1
        }

        vm.join(vm.summaries[0])

        try await eventually(timeout: 0.5) {
            analytics.events.contains(where: { event in
                event.name == "challenge_join_result" && event.params["result"] == .string("failed")
            })
        }
    }

    private static func sampleChallenge(isJoined: Bool) -> ChallengeSummary {
        ChallengeSummary(
            id: "2025-W10-distance",
            title: "Weekly Distance",
            kind: .distance,
            goalValue: 10000,
            unitLabel: "m",
            weekNumber: 10,
            startDate: Date(),
            endDate: Date().addingTimeInterval(7 * 86_400),
            isJoined: isJoined,
            isPremiumGated: false
        )
    }
}

// MARK: - Stubs

private final class ChallengeReaderStub: ChallengeReading {
    let summariesSubject: CurrentValueSubject<[ChallengeSummary], Never>
    private let streakSubject: CurrentValueSubject<StreakInfo, Never>
    private var progressSubjects: [String: CurrentValueSubject<ChallengeProgress, Never>] = [:]

    init(initial: [ChallengeSummary]) {
        self.summariesSubject = .init(initial)
        self.streakSubject = .init(.init(currentStreakWeeks: 0, bestStreakWeeks: 0, onTrackThisWeek: false))
    }

    var summariesPublisher: AnyPublisher<[ChallengeSummary], Never> {
        summariesSubject.eraseToAnyPublisher()
    }

    func progressPublisher(for challengeId: String) -> AnyPublisher<ChallengeProgress, Never> {
        let subject = progressSubjects[challengeId] ?? .init(.init(challengeId: challengeId, currentValue: 0, percent: 0, lastUpdated: Date()))
        progressSubjects[challengeId] = subject
        return subject.eraseToAnyPublisher()
    }

    var streakPublisher: AnyPublisher<StreakInfo, Never> {
        streakSubject.eraseToAnyPublisher()
    }
}

private final class ChallengeActorStub: ChallengeActing {
    var shouldThrowJoin = false
    var shouldThrowLeave = false

    func join(challengeId: String) async throws {
        if shouldThrowJoin { throw StubError.joinFailed }
    }

    func leave(challengeId: String) async throws {
        if shouldThrowLeave { throw StubError.leaveFailed }
    }

    func rulesText(challengeId: String) async -> String { "" }
}

@MainActor
private final class ChallengesAnalyticsLogger: AnalyticsLogging {
    private let spanDelegate = AnalyticsLogger()
    var events: [AnalyticsEvent] = []

    func updateConfig(_ config: AnalyticsLogger.Config) {}

    func log(_ event: AnalyticsEvent) {
        events.append(event)
    }

    func beginSpan(_ span: AnalyticsSpan) -> AnalyticsSpanHandle { spanDelegate.beginSpan(span) }

    func endSpan(_ handle: AnalyticsSpanHandle) { spanDelegate.endSpan(handle) }
}

private enum StubError: Error {
    case joinFailed
    case leaveFailed
}

private enum WaitError: Error { case timeout }

// MARK: - Helpers

private func eventually(timeout: TimeInterval, condition: @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("Condition not met in time")
    throw WaitError.timeout
}
