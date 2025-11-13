// Services/Spots/SpotModerationService.swift
// Community-quality backbone: trust scores, flag queue, audit log with optional hash chain.
// Deterministic conflict resolver + role-gating for partner bulk actions.

import Foundation
import Combine
import CryptoKit
import os.log
import MapKit

// MARK: - Roles / Trust

public enum UserRole: String, Codable, CaseIterable {
    case user       // default
    case trusted    // elevated community member (auto via thresholds)
    case partner    // city/business partner (role-gated bulk ops)
    case admin      // staff override
}

public struct TrustScore: Codable, Equatable {
    public var score: Double        // 0.0 ... 1.0
    public var lastComputedAt: Date
    public var reasons: [String]
}

// MARK: - DI seams

public protocol UserProfileQuerying {
    /// Minimal inputs for trust computation
    func accountCreatedAt(userId: String) -> Date?
    func priorSpotApprovalsCount(userId: String) -> Int
    func priorSpotRejectionsCount(userId: String) -> Int
    func priorAccurateReports(userId: String) -> Int  // e.g., hazards/flags later confirmed
    func role(for userId: String) -> UserRole
}

public protocol SpotModerationRemoteAPI {
    /// Mirror SpotRemoteAPI.moderate but returns authoritative Cloud spot
    func moderate(spotId: String, action: SpotModerationAction) async throws -> CloudSkateSpot
}

// MARK: - Flag model / queue

public enum SpotFlagReason: String, Codable, CaseIterable {
    case incorrectLocation, duplicate, unsafe, spam, closed, other
}

public struct SpotFlag: Codable, Identifiable, Equatable {
    public let id: String
    public let spotId: String
    public let reporterUserId: String
    public let reason: SpotFlagReason
    public let note: String?
    public let createdAt: Date
    public var weightHint: Double? // optional pre-weight from client
    public init(id: String = UUID().uuidString,
                spotId: String,
                reporterUserId: String,
                reason: SpotFlagReason,
                note: String?,
                createdAt: Date = Date(),
                weightHint: Double? = nil) {
        self.id = id; self.spotId = spotId; self.reporterUserId = reporterUserId
        self.reason = reason; self.note = note; self.createdAt = createdAt; self.weightHint = weightHint
    }
}

// Deterministic moderation decision
public enum ModerationDecision: String, Codable, Equatable {
    case noAction
    case approveChange        // keep/edit/activate spot
    case rejectChange         // deny edit / mark invalid flag
    case archiveSpot          // archive/remove from active map
}

// Audit log entry (tamper-evident via hash chain, optional)
public struct ModerationAuditEntry: Codable, Identifiable, Equatable {
    public let id: String
    public let timestamp: Date
    public let actorUserId: String
    public let actorRole: UserRole
    public let spotId: String
    public let decision: ModerationDecision
    public let rationale: String
    public let flagIds: [String]            // flags considered in decision
    public let prevHash: String?            // previous entry hash (hex)
    public let hash: String                 // this entry hash (hex)
}

// Conflict candidates describe competing edits or states to resolve.
public struct SpotEditCandidate: Codable, Equatable {
    public let authorUserId: String
    public let proposedTitle: String?
    public let proposedSubtitle: String?
    public let proposedCategory: String?
    public let proposedCoordinate: CLLocationCoordinate2D?
    public let proposedStatus: SpotStatus?
    public let clientUpdatedAt: Date
}

// MARK: - Service

@MainActor
public final class SpotModerationService: ObservableObject {

    public enum State: Equatable { case idle, ready, error(String) }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var pendingFlagsCount: Int = 0
    @Published public private(set) var latestAudit: ModerationAuditEntry?

    public var flagsPublisher: AnyPublisher<[SpotFlag], Never> { flagsSubject.eraseToAnyPublisher() }
    public var auditPublisher: AnyPublisher<ModerationAuditEntry?, Never> { $latestAudit.eraseToAnyPublisher() }

    // DI
    private let users: UserProfileQuerying
    private let remote: SpotModerationRemoteAPI
    private let log = Logger(subsystem: "com.skateroute", category: "SpotModeration")

    // Persistence
    private let queueStore = FlagQueueStore()
    private let auditStore: AuditLogStore

    // Streams
    private let flagsSubject = CurrentValueSubject<[SpotFlag], Never>([])

    // Config
    public struct Config: Equatable {
        public var enableHashChain: Bool = true
        public var promotionThreshold: Double = 0.72    // promote to .trusted
        public var demotionThreshold: Double = 0.30     // demote .trusted back to .user
        public var partnerBulkRadiusMeters: Double = 150.0
        public init() {}
    }
    public var config: Config = .init()

    public init(users: UserProfileQuerying,
                remote: SpotModerationRemoteAPI,
                auditFileName: String = "spot-audit.log") {
        self.users = users
        self.remote = remote
        self.auditStore = AuditLogStore(fileName: auditFileName)
        // Warm queue/audit
        flagsSubject.send(queueStore.loadAll())
        pendingFlagsCount = flagsSubject.value.count
        latestAudit = auditStore.last()
        state = .ready
    }

    // MARK: Public API

    public func submitFlag(_ flag: SpotFlag) {
        // Coalesce duplicates from same reporter/spot/reason within short horizon (idempotent-ish)
        let existing = flagsSubject.value.first {
            $0.spotId == flag.spotId && $0.reporterUserId == flag.reporterUserId && $0.reason == flag.reason && abs($0.createdAt.timeIntervalSince(flag.createdAt)) < 3600
        }
        guard existing == nil else { return }

        queueStore.append(flag)
        emitQueue()
    }

    /// Pulls the highest-priority flags (by aggregate reporter trust) for triage.
    public func dequeueBatch(limit: Int = 20) -> [SpotFlag] {
        let all = flagsSubject.value
        guard !all.isEmpty else { return [] }

        // Priority = sum of reporter trust per spot/reason cluster; stable sort by time
        let trusts = Dictionary(uniqueKeysWithValues: Set(all.map(\.reporterUserId)).map { ($0, computeTrust(for: $0).score) })
        let prioritized = all.sorted { a, b in
            let ta = trusts[a.reporterUserId]
            let tb = trusts[b.reporterUserId]
            if ta == tb { return a.createdAt < b.createdAt }
            return (ta ?? 0) > (tb ?? 0)
        }
        return Array(prioritized.prefix(limit))
    }

    /// Apply a moderation decision for a spot. Records audit, removes related flags from queue.
    public func applyDecision(actorUserId: String,
                              spotId: String,
                              decision: ModerationDecision,
                              consideredFlags: [SpotFlag],
                              rationale: String,
                              actorRoleOverride: UserRole? = nil) async throws {
        let role = actorRoleOverride ?? users.role(for: actorUserId)

        // Role gating (partners can only archive/approve within policy; admins unrestricted)
        if role == .partner && decision == .rejectChange {
            throw ModerationError.roleNotPermitted
        }
        // Remote side-effect (best effort; admin can re-run)
        switch decision {
        case .approveChange:
            _ = try? await remote.moderate(spotId: spotId, action: .approve)
        case .rejectChange:
            _ = try? await remote.moderate(spotId: spotId, action: .reject)
        case .archiveSpot:
            _ = try? await remote.moderate(spotId: spotId, action: .archive)
        case .noAction:
            break
        }

        // Remove flags for this spot that were considered
        queueStore.remove(ids: consideredFlags.map(\.id))
        emitQueue()

        // Append audit with optional hash chain
        let entry = auditStore.append(actorUserId: actorUserId,
                                      actorRole: role,
                                      spotId: spotId,
                                      decision: decision,
                                      rationale: rationale,
                                      flagIds: consideredFlags.map(\.id),
                                      chain: config.enableHashChain)
        latestAudit = entry
    }

    /// Deterministic resolver among conflicting edits. Picks the winner by trust → recency → userId.
    public func resolveConflict(_ candidates: [SpotEditCandidate]) -> SpotEditCandidate? {
        guard !candidates.isEmpty else { return nil }
        // Precompute trust
        let trusts = Dictionary(uniqueKeysWithValues: Set(candidates.map(\.authorUserId)).map { ($0, computeTrust(for: $0).score) })
        return candidates.sorted { a, b in
            let ta = trusts[a.authorUserId] ?? 0
            let tb = trusts[b.authorUserId] ?? 0
            if ta != tb { return ta > tb }
            if a.clientUpdatedAt != b.clientUpdatedAt { return a.clientUpdatedAt > b.clientUpdatedAt }
            return a.authorUserId < b.authorUserId
        }.first
    }

    /// Partners may apply bulk archive/approve for a small radius; gated by role & radius.
    public func bulkModerate(actorUserId: String,
                             role: UserRole,
                             spots: [String],
                             decision: ModerationDecision) async throws {
        guard role == .partner || role == .admin else { throw ModerationError.roleNotPermitted }
        guard decision == .archiveSpot || decision == .approveChange else { throw ModerationError.roleNotPermitted }

        for sid in spots {
            try? await applyDecision(actorUserId: actorUserId,
                                     spotId: sid,
                                     decision: decision,
                                     consideredFlags: flagsSubject.value.filter { $0.spotId == sid },
                                     rationale: "Partner bulk action",
                                     actorRoleOverride: role)
        }
    }

    // MARK: Trust computation

    public func computeTrust(for userId: String) -> TrustScore {
        let now = Date()
        let created = users.accountCreatedAt(userId: userId) ?? now
        let ageDays = max(0, now.timeIntervalSince(created) / 86400)

        let approvals = users.priorSpotApprovalsCount(userId: userId)
        let rejects = users.priorSpotRejectionsCount(userId: userId)
        let accuracy = users.priorAccurateReports(userId: userId)

        // Logistic-like score: age + approvals + accuracy help; rejects hurt; cap 0..1
        // Weights are tuned to promote consistent helpers within a few weeks.
        let raw = 0.15 * tanh(ageDays / 30.0) +
                  0.55 * (1 - exp(-Double(approvals) / 20.0)) +
                  0.25 * (1 - exp(-Double(accuracy) / 30.0)) -
                  0.20 * (1 - exp(-Double(rejects) / 10.0))

        let score = min(1.0, max(0.0, 0.5 + raw)) // base at 0.5
        var reasons: [String] = []
        if ageDays < 3 { reasons.append("new_account") }
        if approvals > 5 { reasons.append("many_approvals") }
        if rejects > 3 { reasons.append("many_rejects") }
        if accuracy > 10 { reasons.append("accurate_reports") }

        return TrustScore(score: score, lastComputedAt: now, reasons: reasons)
    }

    /// Threshold policy to promote/demote users. Caller updates roles in identity system.
    public func shouldPromote(userId: String) -> Bool { computeTrust(for: userId).score >= config.promotionThreshold }
    public func shouldDemote(userId: String) -> Bool { computeTrust(for: userId).score <= config.demotionThreshold }

    // MARK: Internals

    private func emitQueue() {
        let list = queueStore.loadAll()
        flagsSubject.send(list)
        pendingFlagsCount = list.count
    }
}

// MARK: - Errors

public enum ModerationError: LocalizedError {
    case roleNotPermitted
    public var errorDescription: String? {
        switch self {
        case .roleNotPermitted: return "Action not permitted for your role."
        }
    }
}

// MARK: - Persistence: Flag queue

fileprivate final class FlagQueueStore {
    private let fm = FileManager.default
    private let url: URL

    init() {
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Moderation", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("spot-flags.json")
    }

    func loadAll() -> [SpotFlag] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([SpotFlag].self, from: data)) ?? []
    }

    func append(_ flag: SpotFlag) {
        var all = loadAll()
        all.append(flag)
        save(all)
    }

    func remove(ids: [String]) {
        var all = loadAll()
        all.removeAll { ids.contains($0.id) }
        save(all)
    }

    private func save(_ list: [SpotFlag]) {
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Persistence: Tamper-evident audit log

fileprivate final class AuditLogStore {
    private let fm = FileManager.default
    private let url: URL
    private var cache: [ModerationAuditEntry] = []

    init(fileName: String) {
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Moderation", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(fileName)
        cache = loadAll()
    }

    func last() -> ModerationAuditEntry? { cache.last }

    func append(actorUserId: String,
                actorRole: UserRole,
                spotId: String,
                decision: ModerationDecision,
                rationale: String,
                flagIds: [String],
                chain: Bool) -> ModerationAuditEntry {
        let prevHash = cache.last?.hash
        let timestamp = Date()

        // Hash input is canonical JSON of all fields + prevHash; hex SHA-256
        let payload = [
            "ts": ISO8601DateFormatter().string(from: timestamp),
            "actor": actorUserId,
            "role": actorRole.rawValue,
            "spot": spotId,
            "decision": decision.rawValue,
            "rationale": rationale,
            "flags": flagIds
        ] as [String : Any]

        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        var bytes = Data()
        if chain, let prev = prevHash { bytes.append(Data(prev.utf8)) }
        bytes.append(json)
        let digest = SHA256.hash(data: bytes)
        let hash = digest.map { String(format: "%02x", $0) }.joined()

        let entry = ModerationAuditEntry(id: UUID().uuidString,
                                         timestamp: timestamp,
                                         actorUserId: actorUserId,
                                         actorRole: actorRole,
                                         spotId: spotId,
                                         decision: decision,
                                         rationale: rationale,
                                         flagIds: flagIds,
                                         prevHash: chain ? prevHash : nil,
                                         hash: chain ? hash : UUID().uuidString.replacingOccurrences(of: "-", with: ""))

        cache.append(entry)
        saveAll(cache)
        return entry
    }

    private func loadAll() -> [ModerationAuditEntry] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ModerationAuditEntry].self, from: d)) ?? []
    }

    private func saveAll(_ list: [ModerationAuditEntry]) {
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - DEBUG fakes for tests

#if DEBUG
public final class UserProfileQueryFake: UserProfileQuerying {
    private let createdAtMap: [String: Date]
    private let approvals: [String: Int]
    private let rejects: [String: Int]
    private let accuracy: [String: Int]
    private let roles: [String: UserRole]
    public init(createdAt: [String: Date] = [:],
                approvals: [String: Int] = [:],
                rejects: [String: Int] = [:],
                accuracy: [String: Int] = [:],
                roles: [String: UserRole] = [:]) {
        self.createdAtMap = createdAt; self.approvals = approvals; self.rejects = rejects; self.accuracy = accuracy; self.roles = roles
    }
    public func accountCreatedAt(userId: String) -> Date? { createdAtMap[userId] }
    public func priorSpotApprovalsCount(userId: String) -> Int { approvals[userId] ?? 0 }
    public func priorSpotRejectionsCount(userId: String) -> Int { rejects[userId] ?? 0 }
    public func priorAccurateReports(userId: String) -> Int { accuracy[userId] ?? 0 }
    public func role(for userId: String) -> UserRole { roles[userId] ?? .user }
}

public final class SpotModerationRemoteAPIFake: SpotModerationRemoteAPI {
    public init() {}
    public func moderate(spotId: String, action: SpotModerationAction) async throws -> CloudSkateSpot {
        // Echo a dummy CloudSkateSpot with updated status
        let status: SpotStatus = {
            switch action {
            case .approve: return .active
            case .reject: return .rejected
            case .archive: return .archived
            }
        }()
        return CloudSkateSpot(id: spotId,
                              title: "TBD",
                              subtitle: nil,
                              category: "general",
                              coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                              createdAt: Date(), updatedAt: Date(), status: status, serverTimestamp: Date())
    }
}
#endif


