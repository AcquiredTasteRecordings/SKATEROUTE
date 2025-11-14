// Features/Challenges/ChallengesView.swift
// Weekly challenges: join, track, and celebrate progress.
// - Pulls data from Services/Challenges/ChallengeEngine (distance, actions, streak).
// - Progress bars per active challenge; streak indicator; CTA to (i) rules sheet.
// - One-tap Join/Leave with optimistic UI and rollback on failure.
// - A11y: VO-friendly labels (“Week 45 Distance, 62 percent complete”); ≥44pt targets; Dynamic Type safe.
// - Privacy: reads only local aggregates & server-confirmed counters; no precise GPS exposed here.
// - Perf: lightweight; diffed lists; no heavy map or video in this surface.

import SwiftUI
import Combine
import UIKit

// MARK: - Domain adapters (mirror Services/Challenges)

public struct ChallengeSummary: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case distance, cleanup, streak }

    public let id: String                // e.g., "2025-W45-distance"
    public let title: String             // localized name, e.g., "Weekly Distance"
    public let kind: Kind
    public let goalValue: Double         // meters for distance, count for cleanup
    public let unitLabel: String         // "km", "hazards", …
    public let weekNumber: Int           // ISO week for display (e.g., 45)
    public let startDate: Date           // week start (local calendar)
    public let endDate: Date             // week end (exclusive)
    public let isJoined: Bool            // enrollment
    public let isPremiumGated: Bool      // may be ignored by PaywallRules (safety-first)

    public init(
        id: String,
        title: String,
        kind: Kind,
        goalValue: Double,
        unitLabel: String,
        weekNumber: Int,
        startDate: Date,
        endDate: Date,
        isJoined: Bool,
        isPremiumGated: Bool
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.goalValue = goalValue
        self.unitLabel = unitLabel
        self.weekNumber = weekNumber
        self.startDate = startDate
        self.endDate = endDate
        self.isJoined = isJoined
        self.isPremiumGated = isPremiumGated
    }
}

public struct ChallengeProgress: Equatable, Sendable {
    public let challengeId: String
    public let currentValue: Double      // meters or count
    public let percent: Double           // 0…1
    public let lastUpdated: Date

    public init(challengeId: String, currentValue: Double, percent: Double, lastUpdated: Date) {
        self.challengeId = challengeId
        self.currentValue = currentValue
        self.percent = percent
        self.lastUpdated = lastUpdated
    }
}

public struct StreakInfo: Equatable, Sendable {
    public let currentStreakWeeks: Int   // continuous weeks with ≥ goal met
    public let bestStreakWeeks: Int
    public let onTrackThisWeek: Bool

    public init(currentStreakWeeks: Int, bestStreakWeeks: Int, onTrackThisWeek: Bool) {
        self.currentStreakWeeks = currentStreakWeeks
        self.bestStreakWeeks = bestStreakWeeks
        self.onTrackThisWeek = onTrackThisWeek
    }
}

// MARK: - DI seams

public protocol ChallengeReading: AnyObject {
    var summariesPublisher: AnyPublisher<[ChallengeSummary], Never> { get }
    func progressPublisher(for challengeId: String) -> AnyPublisher<ChallengeProgress, Never>
    var streakPublisher: AnyPublisher<StreakInfo, Never> { get }
}

public protocol ChallengeActing: AnyObject {
    func join(challengeId: String) async throws
    func leave(challengeId: String) async throws
    func rulesText(challengeId: String) async -> String // localized; safe-markdown text
}

// MARK: - ViewModel

@MainActor
public final class ChallengesViewModel: ObservableObject {
    @Published public private(set) var summaries: [ChallengeSummary] = []
    @Published public private(set) var progress: [String: ChallengeProgress] = [:]
    @Published public private(set) var streak: StreakInfo = .init(
        currentStreakWeeks: 0,
        bestStreakWeeks: 0,
        onTrackThisWeek: false
    )

    @Published public var errorMessage: String?
    @Published public var infoMessage: String?
    @Published public var showingRulesFor: ChallengeSummary?

    private let reader: ChallengeReading
    private let actor: ChallengeActing
    private let analytics: AnalyticsLogging?
    private var cancellables = Set<AnyCancellable>()
    private var progressCancellables: [String: AnyCancellable] = [:]

    public init(reader: ChallengeReading, actor: ChallengeActing, analytics: AnalyticsLogging? = nil) {
        self.reader = reader
        self.actor = actor
        self.analytics = analytics
        bind()
    }

    private func bind() {
        reader.summariesPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] newSummaries in
                self?.applySummaries(newSummaries)
            }
            .store(in: &cancellables)

        reader.streakPublisher
            .receive(on: RunLoop.main)
            .assign(to: &$streak)
    }

    private func applySummaries(_ list: [ChallengeSummary]) {
        summaries = list.sorted { a, b in
            // Active week first by startDate; then by title
            if a.startDate != b.startDate { return a.startDate > b.startDate }
            return a.title < b.title
        }

        // Rewire progress subscriptions
        let ids = Set(list.map { $0.id })

        // Cancel obsolete
        for (id, c) in progressCancellables where !ids.contains(id) {
            c.cancel()
            progressCancellables.removeValue(forKey: id)
        }

        // Subscribe new
        for id in ids where progressCancellables[id] == nil {
            let c = reader
                .progressPublisher(for: id)
                .receive(on: RunLoop.main)
                .sink { [weak self] p in
                    self?.progress[id] = p
                }
            progressCancellables[id] = c
        }
    }

    // MARK: - Actions

    public func join(_ ch: ChallengeSummary) {
        guard !ch.isJoined else { return }
        logChallengeEvent("challenge_join_attempt", challenge: ch)
        optimisticToggle(ch, toJoin: true)

        Task {
            do {
                try await actor.join(challengeId: ch.id)
                infoMessage = NSLocalizedString("You’re in. Have a solid week!", comment: "join ok")
                logChallengeEvent("challenge_join_result", challenge: ch, extra: ["result": .string("joined")])
            } catch {
                rollbackToggle(ch)
                errorMessage = NSLocalizedString("Couldn’t join right now.", comment: "join fail")
                logChallengeEvent("challenge_join_result", challenge: ch, extra: ["result": .string("failed")])
            }
        }
    }

    public func leave(_ ch: ChallengeSummary) {
        guard ch.isJoined else { return }
        logChallengeEvent("challenge_leave_attempt", challenge: ch)
        optimisticToggle(ch, toJoin: false)

        Task {
            do {
                try await actor.leave(challengeId: ch.id)
                infoMessage = NSLocalizedString("Left the challenge.", comment: "leave ok")
                logChallengeEvent("challenge_leave_result", challenge: ch, extra: ["result": .string("left")])
            } catch {
                rollbackToggle(ch)
                errorMessage = NSLocalizedString("Couldn’t leave right now.", comment: "leave fail")
                logChallengeEvent("challenge_leave_result", challenge: ch, extra: ["result": .string("failed")])
            }
        }
    }

    private func optimisticToggle(_ ch: ChallengeSummary, toJoin: Bool) {
        guard let idx = summaries.firstIndex(where: { $0.id == ch.id }) else { return }
        let m = summaries[idx]
        let updated = ChallengeSummary(
            id: m.id,
            title: m.title,
            kind: m.kind,
            goalValue: m.goalValue,
            unitLabel: m.unitLabel,
            weekNumber: m.weekNumber,
            startDate: m.startDate,
            endDate: m.endDate,
            isJoined: toJoin,
            isPremiumGated: m.isPremiumGated
        )
        summaries[idx] = updated
    }

    private func rollbackToggle(_ ch: ChallengeSummary) {
        guard let idx = summaries.firstIndex(where: { $0.id == ch.id }) else { return }
        let m = summaries[idx]
        let updated = ChallengeSummary(
            id: m.id,
            title: m.title,
            kind: m.kind,
            goalValue: m.goalValue,
            unitLabel: m.unitLabel,
            weekNumber: m.weekNumber,
            startDate: m.startDate,
            endDate: m.endDate,
            isJoined: !m.isJoined,
            isPremiumGated: m.isPremiumGated
        )
        summaries[idx] = updated
    }

    public func openRules(_ ch: ChallengeSummary) {
        logChallengeEvent("challenge_rules_opened", challenge: ch)
        showingRulesFor = ch
    }

    public func rulesText(for ch: ChallengeSummary) async -> String {
        await actor.rulesText(challengeId: ch.id)
    }

    private func logChallengeEvent(_ name: String, challenge: ChallengeSummary, extra: [String: AnalyticsValue] = [:]) {
        guard let analytics else { return }
        var params: [String: AnalyticsValue] = [
            "challenge_id": .string(challenge.id),
            "kind": .string(challenge.kind.rawValue),
            "week": .int(challenge.weekNumber),
            "premium": .bool(challenge.isPremiumGated)
        ]
        for (k, v) in extra { params[k] = v }
        analytics.log(.init(name: name, category: .challenges, params: params))
    }
}

// MARK: - View

public struct ChallengesView: View {
    @ObservedObject private var vm: ChallengesViewModel
    @State private var rulesText: String = ""
    @State private var loadingRules = false

    public init(viewModel: ChallengesViewModel) {
        self.vm = viewModel
    }

    public var body: some View {
        List {
            streakCard

            Section(header: header) {
                ForEach(vm.summaries) { ch in
                    ChallengeRow(
                        ch: ch,
                        prog: vm.progress[ch.id],
                        join: { vm.join(ch) },
                        leave: { vm.leave(ch) },
                        rules: { vm.openRules(ch) }
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text(NSLocalizedString("Challenges", comment: "title")))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $vm.showingRulesFor, onDismiss: { rulesText = "" }) { ch in
            RulesSheet(
                title: ch.title,
                load: {
                    if rulesText.isEmpty {
                        loadingRules = true
                        Task {
                            rulesText = await vm.rulesText(for: ch)
                            loadingRules = false
                        }
                    }
                },
                text: $rulesText,
                loading: $loadingRules
            )
        }
        .overlay(toasts)
        .accessibilityIdentifier("challenges_list")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "flag.checkered")
                .imageScale(.medium)
            Text(NSLocalizedString("This Week", comment: "this week"))
                .font(.subheadline.weight(.semibold))
        }
        .accessibilityHidden(true)
    }

    private var streakCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(NSLocalizedString("Streak", comment: "streak"), systemImage: "flame.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if vm.streak.onTrackThisWeek {
                    Label(NSLocalizedString("On track", comment: "on track"), systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.12), in: Capsule())
                }
            }
            HStack(spacing: 12) {
                StreakPill(
                    title: NSLocalizedString("Current", comment: "cur"),
                    value: vm.streak.currentStreakWeeks
                )
                StreakPill(
                    title: NSLocalizedString("Best", comment: "best"),
                    value: vm.streak.bestStreakWeeks
                )
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                Text(
                    "\(vm.streak.currentStreakWeeks) week current streak. Best \(vm.streak.bestStreakWeeks) weeks."
                )
            )
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .listRowInsets(EdgeInsets())
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .accessibilityIdentifier("streak_card")
    }

    // MARK: Toasts

    @ViewBuilder
    private var toasts: some View {
        VStack {
            Spacer()
            if let msg = vm.errorMessage {
                toast(text: msg, system: "exclamationmark.triangle.fill", bg: .red)
                    .onAppear { autoDismiss { vm.errorMessage = nil } }
            } else if let info = vm.infoMessage {
                toast(text: info, system: "checkmark.seal.fill", bg: .green)
                    .onAppear { autoDismiss { vm.infoMessage = nil } }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .animation(
            .easeInOut,
            value: vm.errorMessage != nil || vm.infoMessage != nil
        )
    }

    private func toast(text: String, system: String, bg: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: system)
                .imageScale(.large)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.leading)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(bg.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
        .foregroundColor(.white)
        .accessibilityLabel(Text(text))
    }

    private func autoDismiss(_ body: @escaping () -> Void) {
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await MainActor.run { body() }
        }
    }
}

// MARK: - Row

fileprivate struct ChallengeRow: View {
    let ch: ChallengeSummary
    let prog: ChallengeProgress?
    let join: () -> Void
    let leave: () -> Void
    let rules: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rowTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(weekLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if ch.isPremiumGated {
                    Label(
                        NSLocalizedString("Premium", comment: "premium"),
                        systemImage: "star.fill"
                    )
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.yellow.opacity(0.2), in: Capsule())
                    .accessibilityLabel(
                        Text(NSLocalizedString("Premium challenge", comment: ""))
                    )
                }
            }

            // Progress bar
            HStack(spacing: 10) {
                ProgressView(value: min(max(prog?.percent ?? 0, 0), 1))
                    .progressViewStyle(.linear)
                    .frame(height: 4)
                    .tint(.accentColor)
                    .accessibilityLabel(Text("\(ch.title) progress"))
                    .accessibilityValue(Text(progressAX))
                Text(progressText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Actions
            HStack(spacing: 8) {
                if ch.isJoined {
                    Button(action: leave) {
                        Label(
                            NSLocalizedString("Leave", comment: "leave"),
                            systemImage: "person.crop.circle.badge.minus"
                        )
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(action: join) {
                        Label(
                            NSLocalizedString("Join", comment: "join"),
                            systemImage: "person.crop.circle.badge.plus"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button(action: rules) {
                    Label(
                        NSLocalizedString("Rules", comment: "rules"),
                        systemImage: "info.circle"
                    )
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .frame(minHeight: 44)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text("\(rowTitle). \(progressAX).")
        )
    }

    private var rowTitle: String {
        switch ch.kind {
        case .distance: return ch.title
        case .cleanup:  return ch.title
        case .streak:   return ch.title
        }
    }

    private var weekLabel: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .none
        return String(
            format: NSLocalizedString("Week %d • %@–%@", comment: "week"),
            ch.weekNumber,
            fmt.string(from: ch.startDate),
            fmt.string(from: ch.endDate.addingTimeInterval(-86_400))
        )
    }

    private var progressText: String {
        let v = prog?.currentValue ?? 0
        if ch.unitLabel == "km" {
            return String(format: "%.1f / %.1f km", v / 1000, ch.goalValue / 1000)
        } else {
            return String(format: "%.0f / %.0f %@", v, ch.goalValue, ch.unitLabel)
        }
    }

    private var progressAX: String {
        let percent = Int(round((prog?.percent ?? 0) * 100))
        return String(
            format: NSLocalizedString("%d percent complete", comment: "ax percent"),
            percent
        )
    }
}

// MARK: - Streak pill

fileprivate struct StreakPill: View {
    let title: String
    let value: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "flame.fill")
                .imageScale(.small)
            Text(title)
                .font(.caption2.weight(.semibold))
            Text("\(value)")
                .font(.callout.monospacedDigit().weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.15), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title) \(value)"))
    }
}

// MARK: - Rules sheet

fileprivate struct RulesSheet: View {
    let title: String
    let load: () -> Void
    @Binding var text: String
    @Binding var loading: Bool

    var body: some View {
        NavigationView {
            Group {
                if loading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        Text(
                            text.isEmpty
                            ? NSLocalizedString("Rules unavailable.", comment: "no rules")
                            : text
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                }
            }
            .navigationTitle(Text(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Close", comment: "close")) {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil,
                            from: nil,
                            for: nil
                        )
                    }
                }
            }
            .onAppear(perform: load)
        }
    }
}

// MARK: - Convenience builder

public extension ChallengesView {
    static func make(
        reader: ChallengeReading,
        actor: ChallengeActing,
        analytics: AnalyticsLogging? = nil
    ) -> ChallengesView {
        ChallengesView(viewModel: .init(reader: reader, actor: actor, analytics: analytics))
    }
}

// MARK: - DEBUG fakes

#if DEBUG
final class ReaderFake: ChallengeReading {
    private let summariesSubj = CurrentValueSubject<[ChallengeSummary], Never>([])
    private let streakSubj = CurrentValueSubject<StreakInfo, Never>(
        .init(currentStreakWeeks: 3, bestStreakWeeks: 7, onTrackThisWeek: true)
    )

    func progressPublisher(for challengeId: String) -> AnyPublisher<ChallengeProgress, Never> {
        let start = Double(Int.random(in: 0 ... 5_000))
        let subj = CurrentValueSubject<ChallengeProgress, Never>(
            .init(
                challengeId: challengeId,
                currentValue: start,
                percent: min(start / 10_000.0, 1.0),
                lastUpdated: Date()
            )
        )

        // Simulate ticking progress
        Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                let nextVal = min(
                    subj.value.currentValue + Double(Int.random(in: 120 ... 680)),
                    10_000
                )
                subj.send(
                    .init(
                        challengeId: challengeId,
                        currentValue: nextVal,
                        percent: nextVal / 10_000.0,
                        lastUpdated: Date()
                    )
                )
            }
            .store(in: &cancellables)

        return subj.eraseToAnyPublisher()
    }

    var summariesPublisher: AnyPublisher<[ChallengeSummary], Never> {
        summariesSubj.eraseToAnyPublisher()
    }

    var streakPublisher: AnyPublisher<StreakInfo, Never> {
        streakSubj.eraseToAnyPublisher()
    }

    private var cancellables = Set<AnyCancellable>()

    init(now: Date = Date()) {
        let cal = Calendar.current
        let week = cal.component(.weekOfYear, from: now)
        let start = cal.date(
            from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        ) ?? now
        let end = cal.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7 * 86_400)

        summariesSubj.send([
            .init(
                id: "W\(week)-distance",
                title: "Weekly Distance",
                kind: .distance,
                goalValue: 10_000,
                unitLabel: "km",
                weekNumber: week,
                startDate: start,
                endDate: end,
                isJoined: true,
                isPremiumGated: false
            ),
            .init(
                id: "W\(week)-cleanup",
                title: "Hazard Clean-up",
                kind: .cleanup,
                goalValue: 5,
                unitLabel: NSLocalizedString("hazards", comment: "hazards"),
                weekNumber: week,
                startDate: start,
                endDate: end,
                isJoined: false,
                isPremiumGated: false
            )
        ])
    }
}

final class ActorFake: ChallengeActing {
    func join(challengeId: String) async throws { }
    func leave(challengeId: String) async throws { }

    func rulesText(challengeId: String) async -> String {
        """
        • Log distance by recording rides with SkateRoute this week.
        • Cleanup = mark + verify hazard resolutions.
        • Stay safe: never chase goals in sketchy conditions.
        """
    }
}

struct ChallengesView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            ChallengesView.make(reader: ReaderFake(), actor: ActorFake())
        }
        .preferredColorScheme(.dark)
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
    }
}
#endif

// MARK: - Integration notes
// • Hook `ChallengeReading` to Services/Challenges/ChallengeEngine publishers:
//   - summariesPublisher: emits current week challenges with join state.
//   - progressPublisher(challengeId:): emits rolling aggregates from SessionLogger NDJSON + server-confirmed actions.
//   - streakPublisher: computed by engine (week rollovers, locale-aware).
// • Respect PaywallRules: Premium-gated challenges should still *display*, but joining may soft-gate with ethical paywall.
// • Rules text can be Markdown; render plain here for safety while riding. If rich text is desired, render in a WKWebView only when stationary.
// • Analytics: log join/leave, rules open in the service layer; never log precise distance traces from here.
// • UITests: verify identifiers “challenges_list”, “streak_card”; joining flips button state and shows toast.

// MARK: - Test plan (unit/UI)
// Unit:
// 1) ViewModel binds: publish summaries → rows update; progressPublisher values map to correct rows.
// 2) Join/Leave optimistic update → failure rolls back; success emits info toast.
// 3) Rules flow: opening sheet triggers async rulesText; content displays when loaded.
// 4) Sorting: newer startDate first; stable ordering for same week.
// UI:
// • Dynamic Type XXL keeps controls ≥44pt; VO reads “Weekly Distance, 62 percent complete.”
// • Accessibility identifiers: “challenges_list”, “streak_card”.
// • Snapshot: progress bars clamp 0…1; premium badge visible on gated items.
