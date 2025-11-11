// Services/Challenges/ChallengeEngine.swift
// Weekly distance & hazard clean-up challenges + streaks.
// Reads SessionLogger NDJSON ride files, aggregates progress, emits badges via RewardsWallet.
// Locale-aware week rollovers. Backfill-safe. No PII. No tracking.

import Foundation
import Combine
import os.log

// MARK: - DI seams

public protocol RewardsWalleting {
    /// Mint a badge once (idempotent). Implementer must ensure duplicate-safe storage.
    func earnBadge(id: String, name: String, metadata: [String: String]) async
}

public protocol DateProviding {
    var now: Date { get }
}
public struct SystemClock: DateProviding { public var now: Date { Date() } }

public protocol CalendarProviding {
    var calendar: Calendar { get } // locale-aware; inject ISO-8601 if you prefer fixed weeks
}
public struct SystemCalendar: CalendarProviding { public var calendar: Calendar { Calendar.autoupdatingCurrent } }

// MARK: - NDJSON ride log contract (tolerant parser)

/// We accept multiple shapes; contract is “distance delta, timestamps, action type”.
/// Examples of accepted lines:
/// {"ts":1698799601.2,"type":"loc","delta_distance_m":3.4}
/// {"ts":"2024-10-31T00:00:00Z","type":"hazard_resolved","hazard_id":"H123"}
/// {"ts":1698799700,"type":"ride_start"} / {"type":"ride_stop"}
fileprivate struct NDJSONLine: Decodable {
    let ts: Timestamp
    let type: String
    let deltaDistanceM: Double?
    let hazardId: String?
    enum CodingKeys: String, CodingKey {
        case ts, type, deltaDistanceM = "delta_distance_m", hazardId = "hazard_id"
    }
    enum Timestamp: Decodable {
        case double(Double), string(String)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { self = .double(d); return }
            let s = try c.decode(String.self); self = .string(s)
        }
        func date() -> Date? {
            switch self {
            case .double(let t): return Date(timeIntervalSince1970: t)
            case .string(let s):
                // Try ISO8601, then RFC3339-ish
                let iso = ISO8601DateFormatter()
                if let d = iso.date(from: s) { return d }
                // Naive fallback
                return Date(timeIntervalSince1970: TimeInterval(Double(s) ?? 0))
            }
        }
    }
}

// MARK: - Public models

public struct WeeklyProgress: Sendable, Equatable {
    public let weekStart: Date          // startOfWeek (midnight) in local calendar
    public let weekEnd: Date            // exclusive
    public let distanceMeters: Double
    public let hazardCleanups: Int
    public let metDistanceGoal: Bool
    public let metCleanupGoal: Bool
}

public struct ChallengeSnapshot: Sendable, Equatable {
    public let currentWeek: WeeklyProgress
    public let lastWeeks: [WeeklyProgress]       // most-recent-first
    public let distanceStreakWeeks: Int          // consecutive weeks meeting distance goal, up to current
    public let cleanupStreakWeeks: Int           // consecutive weeks meeting cleanup goal, up to current
}

// MARK: - Config

public struct ChallengeConfig: Equatable {
    public var weeklyDistanceGoalMeters: Double = 20_000    // ~20 km
    public var weeklyCleanupGoalCount: Int = 3              // e.g., remove or resolve 3 hazards
    public var ridesDirName: String = "Rides"               // SessionLogger dir name under AppSupport
    public var maxWeeksTracked: Int = 26                    // roughly two seasons visible
    public init() {}
}

// MARK: - Engine

@MainActor
public final class ChallengeEngine: ObservableObject {

    public enum State: Equatable { case idle, indexing, ready, error(String) }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var snapshot: ChallengeSnapshot

    public var snapshotPublisher: AnyPublisher<ChallengeSnapshot, Never> { $snapshot.eraseToAnyPublisher() }

    // DI
    private let rewards: RewardsWalleting
    private let clock: DateProviding
    private let calProvider: CalendarProviding
    private var calendar: Calendar { calProvider.calendar }
    private let config: ChallengeConfig

    // IO
    private let fm = FileManager.default
    private let log = Logger(subsystem: "com.skateroute", category: "ChallengeEngine")
    private let ridesRoot: URL

    // Cache (in-memory)
    private var weekly: [Date: (distance: Double, cleanups: Int)] = [:] // keyed by startOfWeek

    // MARK: Init

    public init(rewards: RewardsWalleting,
                clock: DateProviding = SystemClock(),
                calendar: CalendarProviding = SystemCalendar(),
                config: ChallengeConfig = .init()) {
        self.rewards = rewards
        self.clock = clock
        self.calProvider = calendar
        self.config = config
        // Build rides root
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent(config.ridesDirName, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        self.ridesRoot = dir

        // Seed empty snapshot
        let (start, end) = Self.weekBounds(containing: clock.now, using: calendar.calendar)
        self.snapshot = ChallengeSnapshot(
            currentWeek: WeeklyProgress(weekStart: start, weekEnd: end, distanceMeters: 0, hazardCleanups: 0, metDistanceGoal: false, metCleanupGoal: false),
            lastWeeks: [],
            distanceStreakWeeks: 0,
            cleanupStreakWeeks: 0
        )
    }

    // MARK: Public API

    /// Full rescan of NDJSON rides. Use on cold start or when importing past rides.
    public func rescanAll() async {
        state = .indexing
        weekly.removeAll(keepingCapacity: true)

        do {
            let files = try ndjsonFilesSortedNewestFirst()
            for url in files {
                try await ingest(file: url) // tolerant parse
            }
            publishAndBadge()
            state = .ready
        } catch {
            state = .error("Challenge index failed")
            log.error("Challenge rescan error: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ingest a newly finished ride (call when SessionLogger.stop() completes a file).
    public func ingestNewRide(sessionId: String) async {
        let url = ridesRoot.appendingPathComponent("\(sessionId).ndjson")
        guard fm.fileExists(atPath: url.path) else { return }
        do {
            try await ingest(file: url)
            publishAndBadge()
            state = .ready
        } catch {
            // Non-fatal; next rescan will catch it
            log.notice("Ingest new ride failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Force recompute streaks and snapshot from current in-memory data (e.g., after locale change).
    public func recompute() {
        publishAndBadge()
    }

    // MARK: Internals — ingest & aggregate

    private func ingest(file url: URL) async throws {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }

        for try await line in url.lines() {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard let data = line.data(using: .utf8) else { continue }
            guard let model = try? JSONDecoder().decode(NDJSONLine.self, from: data) else { continue }
            guard let date = model.ts.date() else { continue }

            let weekStart = Self.startOfWeek(for: date, using: calendar)
            var bucket = weekly[weekStart] ?? (0, 0)

            // Distance accumulation (sum deltas; tolerate missing field)
            if let d = model.deltaDistanceM, d.isFinite, d > 0 {
                bucket.distance += d
            }

            // Cleanup actions
            switch model.type.lowercased() {
            case "hazard_resolved", "hazard_cleanup", "hazard_removed":
                bucket.cleanups += 1
            default:
                break
            }

            weekly[weekStart] = bucket
        }
    }

    // MARK: Snapshot + badges

    private func publishAndBadge() {
        // Build ordered weeks (most recent first) limited by config
        let orderedStarts = weekly.keys.sorted(by: >)
        let take = Array(orderedStarts.prefix(config.maxWeeksTracked))

        var weeklyModels: [WeeklyProgress] = []
        for wStart in take {
            let (start, end) = Self.weekBounds(startOfWeek: wStart, using: calendar)
            let agg = weekly[wStart] ?? (0, 0)
            weeklyModels.append(WeeklyProgress(weekStart: start,
                                               weekEnd: end,
                                               distanceMeters: agg.distance,
                                               hazardCleanups: agg.cleanups,
                                               metDistanceGoal: agg.distance >= config.weeklyDistanceGoalMeters,
                                               metCleanupGoal: agg.cleanups >= config.weeklyCleanupGoalCount))
        }

        // Ensure current week exists
        let (curStart, curEnd) = Self.weekBounds(containing: clock.now, using: calendar)
        if weeklyModels.first?.weekStart != curStart {
            let agg = weekly[curStart] ?? (0, 0)
            let current = WeeklyProgress(weekStart: curStart, weekEnd: curEnd,
                                         distanceMeters: agg.distance,
                                         hazardCleanups: agg.cleanups,
                                         metDistanceGoal: agg.distance >= config.weeklyDistanceGoalMeters,
                                         metCleanupGoal: agg.cleanups >= config.weeklyCleanupGoalCount)
            // Insert current at front; trim
            weeklyModels.insert(current, at: 0)
            weeklyModels = Array(weeklyModels.prefix(config.maxWeeksTracked))
        }

        // Streaks (consecutive from current backward)
        let distanceStreak = Self.streakCount(weeklyModels, predicate: { $0.metDistanceGoal })
        let cleanupStreak  = Self.streakCount(weeklyModels, predicate: { $0.metCleanupGoal })

        // Publish
        let snapshot = ChallengeSnapshot(currentWeek: weeklyModels.first ?? self.snapshot.currentWeek,
                                         lastWeeks: Array(weeklyModels.dropFirst()),
                                         distanceStreakWeeks: distanceStreak,
                                         cleanupStreakWeeks: cleanupStreak)
        self.snapshot = snapshot

        // Badges (fire-and-forget; idempotent naming)
        Task.detached { [snapshot, rewards] in
            // Weekly completions
            if snapshot.currentWeek.metDistanceGoal {
                let id = Self.badgeId("week_distance", date: snapshot.currentWeek.weekStart)
                await rewards.earnBadge(id: id, name: "Weekly Distance", metadata: [
                    "meters": "\(Int(snapshot.currentWeek.distanceMeters))",
                    "weekStart": "\(snapshot.currentWeek.weekStart.timeIntervalSince1970)"
                ])
            }
            if snapshot.currentWeek.metCleanupGoal {
                let id = Self.badgeId("week_cleanup", date: snapshot.currentWeek.weekStart)
                await rewards.earnBadge(id: id, name: "Clean-Up Crew", metadata: [
                    "count": "\(snapshot.currentWeek.hazardCleanups)",
                    "weekStart": "\(snapshot.currentWeek.weekStart.timeIntervalSince1970)"
                ])
            }
            // Streak milestones (3, 5, 10, 20)
            for milestone in [3, 5, 10, 20] {
                if snapshot.distanceStreakWeeks == milestone {
                    await rewards.earnBadge(id: "streak_distance_\(milestone)", name: "Streak \(milestone)×", metadata: [:])
                }
                if snapshot.cleanupStreakWeeks == milestone {
                    await rewards.earnBadge(id: "streak_cleanup_\(milestone)", name: "Cleanup Streak \(milestone)×", metadata: [:])
                }
            }
        }
    }

    // MARK: Utilities

    private func ndjsonFilesSortedNewestFirst() throws -> [URL] {
        let contents = try fm.contentsOfDirectory(at: ridesRoot, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        return contents
            .filter { $0.lastPathComponent.hasSuffix(".ndjson") }
            .sorted { (a, b) -> Bool in
                let ad = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let bd = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return ad > bd
            }
    }

    private static func streakCount(_ weeks: [WeeklyProgress], predicate: (WeeklyProgress) -> Bool) -> Int {
        var c = 0
        for w in weeks {
            if predicate(w) { c += 1 } else { break }
        }
        return c
    }

    private static func badgeId(_ kind: String, date: Date) -> String {
        // YYYY-WW using ISO week components for stable IDs across locales
        var iso = Calendar(identifier: .iso8601)
        iso.firstWeekday = 2 // Monday
        let comps = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        let yy = comps.yearForWeekOfYear ?? 0
        let ww = comps.weekOfYear ?? 0
        return "\(kind)_\(yy)W\(String(format: "%02d", ww))"
    }

    private static func startOfWeek(for date: Date, using cal: Calendar) -> Date {
        let (start, _) = weekBounds(containing: date, using: cal)
        return start
    }

    private static func weekBounds(containing date: Date, using cal: Calendar) -> (start: Date, end: Date) {
        let startOfDay = cal.startOfDay(for: date)
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: startOfDay)
        let start = cal.date(from: comps) ?? startOfDay
        let end = cal.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7*86_400)
        return (start, end)
    }

    private static func weekBounds(startOfWeek: Date, using cal: Calendar) -> (start: Date, end: Date) {
        let start = cal.startOfDay(for: startOfWeek)
        let end = cal.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7*86_400)
        return (start, end)
    }
}

// MARK: - Async line reader helper (no blocking)

fileprivate extension URL {
    struct LineAsyncSequence: AsyncSequence {
        typealias Element = String
        let url: URL
        func makeAsyncIterator() -> Iterator { Iterator(url: url) }
        struct Iterator: AsyncIteratorProtocol {
            let fh: FileHandle?
            init(url: URL) { fh = try? FileHandle(forReadingFrom: url) }
            mutating func next() async throws -> String? {
                guard let fh else { return nil }
                let delim = Data([0x0a]) // \n
                var buffer = Data()
                while true {
                    let chunk = try fh.read(upToCount: 1)
                    if chunk?.isEmpty ?? true { return buffer.isEmpty ? nil : String(data: buffer, encoding: .utf8) }
                    if chunk == delim { return String(data: buffer, encoding: .utf8) }
                    buffer.append(contentsOf: chunk!)
                }
            }
        }
    }
    func lines() -> LineAsyncSequence { LineAsyncSequence(url: self) }
}

// MARK: - DEBUG fakes (for tests)

#if DEBUG
public final class RewardsWalletFake: RewardsWalleting {
    public private(set) var minted: [String: (name: String, metadata: [String: String])] = [:]
    public init() {}
    public func earnBadge(id: String, name: String, metadata: [String : String]) async {
        // Idempotent by id
        minted[id] = (name, metadata)
    }
}

public struct FixedClock: DateProviding { public var now: Date; public init(_ d: Date) { now = d } }
public struct FixedCalendar: CalendarProviding { public var calendar: Calendar; public init(_ cal: Calendar) { calendar = cal } }
#endif

// MARK: - Test plan (unit/E2E summary)
//
// • Week rollover (locale-aware):
//   - Inject FixedCalendar with firstWeekday = 2 (Mon) for ISO behavior and with 1 (Sun) for US behavior.
//   - Seed NDJSON lines across a boundary (Sun/Mon) and assert startOfWeek changes accordingly.
//   - Assert badgeId uses ISO week for stability.
//
// • Streak breaks:
//   - Build three consecutive weeks meeting distance, then a gap, then current meets cleanup only.
//   - Assert distanceStreakWeeks resets at the gap; cleanupStreak computed independently.
//
// • Backfilled ride import:
//   - Create NDJSON files dated in previous weeks, call rescanAll(), then add a new file in current week and call ingestNewRide().
//   - Assert weekly buckets include both historical and current, ordered most recent first, and streaks update.
//
// • Tolerant parsing:
//   - Lines missing delta_distance_m are ignored for distance but still count hazard_resolved actions.
//   - Mixed timestamp formats (double epoch vs ISO string) decode without throwing.
//
// • Badge idempotency:
//   - With RewardsWalletFake, ensure re-running publishAndBadge() does not create duplicate entries for the same id.
//   - Assert milestone streak badges (3, 5, 10, 20) only appear at exact thresholds.
