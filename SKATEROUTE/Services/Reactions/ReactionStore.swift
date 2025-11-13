// Services/Reactions/ReactionStore.swift
// Local write-through cache for likes/cheers/bookmarks with idempotent remote sync.
// Soft delete, offline queue, conflict resolution, and duplicate suppression.

import Foundation
import Combine
import os.log
import CryptoKit

// MARK: - Public Contracts

public enum ReactionType: String, Codable, CaseIterable, Sendable {
    case like, cheer, bookmark
}

public protocol ReactionRemoteAPI {
    /// Upsert a reaction (active=true/false acts as soft delete). Must be idempotent via key.
    func upsert(idempotencyKey: String,
                userId: String,
                itemId: String,
                type: ReactionType,
                active: Bool,
                clientUpdatedAt: Date) async throws -> RemoteReactionAck
    /// Optional server fetch (used by conflict resolver when needed)
    func fetch(userId: String, itemId: String, type: ReactionType) async throws -> RemoteReactionAck?
}

/// Minimal server echo used for conflict resolution.
public struct RemoteReactionAck: Codable, Equatable {
    public let userId: String
    public let itemId: String
    public let type: ReactionType
    public let active: Bool         // false = soft-deleted on server
    public let serverUpdatedAt: Date
}

// MARK: - Store

@MainActor
public final class ReactionStore: ObservableObject {

    public struct State: Equatable {
        public let userId: String
        public let itemId: String
        public let type: ReactionType
        public let active: Bool
        public let locallyDirty: Bool     // true if pending sync
        public let lastUpdatedAt: Date
    }

    // Public publisher consumers can bind to (e.g., like button tint)
    @Published public private(set) var states: [ReactionKey: State] = [:]
    public var statesPublisher: AnyPublisher<[ReactionKey: State], Never> { $states.eraseToAnyPublisher() }

    // MARK: Init

    private let remote: ReactionRemoteAPI
    private let log = Logger(subsystem: "com.skateroute", category: "ReactionStore")
    private let cache = ReactionDiskCache()
    private let queue = ReactionQueueStore()
    private var syncing = false

    public init(remote: ReactionRemoteAPI) {
        self.remote = remote
        // Warm local cache
        let snapshot = cache.loadAll()
        self.states = snapshot.reduce(into: [:]) { dict, rec in
            dict[rec.key] = State(userId: rec.key.userId,
                                  itemId: rec.key.itemId,
                                  type: rec.key.type,
                                  active: rec.active,
                                  locallyDirty: rec.dirty,
                                  lastUpdatedAt: rec.updatedAt)
        }
    }

    // MARK: Public API

    /// Set a reaction active/inactive (soft delete). Idempotent and coalescing.
    public func setReaction(userId: String, itemId: String, type: ReactionType, active: Bool) {
        let key = ReactionKey(userId: userId, itemId: itemId, type: type)
        var record = cache.load(key: key) ?? ReactionRecord(key: key, active: false, updatedAt: .distantPast, dirty: false)

        // No-op if state unchanged and not dirty
        if record.active == active, record.dirty == false { return }

        // Local write-through
        record.active = active
        record.updatedAt = Date()
        record.dirty = true
        cache.save(record)

        states[key] = State(userId: key.userId,
                            itemId: key.itemId,
                            type: key.type,
                            active: active,
                            locallyDirty: true,
                            lastUpdatedAt: record.updatedAt)

        // Queue a coalesced operation (latest write wins per key)
        queue.enqueueOrReplaceLatest(for: key, desiredActive: active, clientUpdatedAt: record.updatedAt)

        // Kick opportunistic sync
        Task { await sync() }
    }

    /// Convenience UX hook (e.g., double-tap like).
    public func toggle(userId: String, itemId: String, type: ReactionType) {
        let key = ReactionKey(userId: userId, itemId: itemId, type: type)
        let active = !(states[key]?.active ?? false)
        setReaction(userId: userId, itemId: itemId, type: type, active: active)
    }

    /// Current state for a specific reaction.
    public func status(for userId: String, itemId: String, type: ReactionType) -> State {
        let key = ReactionKey(userId: userId, itemId: itemId, type: type)
        return states[key] ?? State(userId: userId, itemId: itemId, type: type, active: false, locallyDirty: false, lastUpdatedAt: .distantPast)
    }

    /// Number of pending items (DiagnosticsView).
    public func pendingCount() -> Int { queue.loadAll().count }

    /// Manual sync trigger (App comes online, pull-to-refresh, etc.)
    public func sync() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }

        // Process until queue drains or progress stalls
        var madeProgress = true
        while madeProgress {
            madeProgress = false
            let batch = queue.loadBatch(limit: 24)
            if batch.isEmpty { break }

            for op in batch {
                // Build deterministic idempotency key: hash(userId|itemId|type)
                let idem = Self.idempotencyKey(op.key)

                // If a newer local write exists, skip this op (coalesced)
                if let latest = queue.latest(for: op.key), latest.clientUpdatedAt > op.clientUpdatedAt {
                    queue.drop(opId: op.id) // obsolete
                    continue
                }

                do {
                    let ack = try await remote.upsert(idempotencyKey: idem,
                                                      userId: op.key.userId,
                                                      itemId: op.key.itemId,
                                                      type: op.key.type,
                                                      active: op.desiredActive,
                                                      clientUpdatedAt: op.clientUpdatedAt)
                    // Conflict resolver: server timestamp bias
                    applyServerAck(ack)
                    queue.drop(opId: op.id)
                    madeProgress = true
                } catch {
                    // On transient errors we keep the op. Backoff handled by caller scheduling.
                    log.notice("Reaction sync failed (will retry): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // Persist latest states to disk
        snapshotStatesToDisk()
    }

    // MARK: Internals

    private func applyServerAck(_ ack: RemoteReactionAck) {
        let key = ReactionKey(userId: ack.userId, itemId: ack.itemId, type: ack.type)
        var local = cache.load(key: key) ?? ReactionRecord(key: key, active: false, updatedAt: .distantPast, dirty: false)

        // If local write is newer than server ack (clock skew tolerance), keep local but remain dirty.
        let skew: TimeInterval = 2.0
        if local.updatedAt > ack.serverUpdatedAt.addingTimeInterval(skew) {
            // Keep local; do nothing (will re-sync).
            states[key] = State(userId: key.userId, itemId: key.itemId, type: key.type, active: local.active, locallyDirty: true, lastUpdatedAt: local.updatedAt)
            return
        }

        // Apply server state and clear dirty.
        local.active = ack.active
        local.updatedAt = ack.serverUpdatedAt
        local.dirty = false
        cache.save(local)

        states[key] = State(userId: key.userId,
                            itemId: key.itemId,
                            type: key.type,
                            active: ack.active,
                            locallyDirty: false,
                            lastUpdatedAt: ack.serverUpdatedAt)
    }

    private func snapshotStatesToDisk() {
        // Write all in-memory states to cache for cold start speed
        for (k, s) in states {
            let rec = ReactionRecord(key: k, active: s.active, updatedAt: s.lastUpdatedAt, dirty: s.locallyDirty)
            cache.save(rec)
        }
    }

    private static func idempotencyKey(_ key: ReactionKey) -> String {
        let input = "\(key.userId)|\(key.itemId)|\(key.type.rawValue)"
        let digest = SHA256.hash(data: input.data(using: .utf8)!)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Models & Persistence

public struct ReactionKey: Hashable, Codable {
    public let userId: String
    public let itemId: String
    public let type: ReactionType
    public init(userId: String, itemId: String, type: ReactionType) {
        self.userId = userId; self.itemId = itemId; self.type = type
    }
}

fileprivate struct ReactionRecord: Codable, Equatable {
    let key: ReactionKey
    var active: Bool
    var updatedAt: Date
    var dirty: Bool
}

fileprivate final class ReactionDiskCache {
    private let fm = FileManager.default
    private let fileURL: URL

    init() {
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Reactions", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("cache.json")
    }

    func loadAll() -> [ReactionRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ReactionRecord].self, from: data)) ?? []
    }

    func load(key: ReactionKey) -> ReactionRecord? {
        loadAll().first { $0.key == key }
    }

    func save(_ rec: ReactionRecord) {
        var all = loadAll().filter { $0.key != rec.key }
        all.append(rec)
        saveAll(all)
    }

    private func saveAll(_ items: [ReactionRecord]) {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - Offline Queue (coalescing + backoff handled by caller scheduling)

fileprivate struct ReactionOp: Codable, Equatable, Identifiable {
    let id: String
    let key: ReactionKey
    let desiredActive: Bool
    let clientUpdatedAt: Date
}

fileprivate final class ReactionQueueStore {
    private let fm = FileManager.default
    private let fileURL: URL
    private var cache: [ReactionOp] = []

    init() {
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Reactions", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("queue.json")
        cache = loadAll()
    }

    func loadAll() -> [ReactionOp] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ReactionOp].self, from: data)) ?? []
    }

    func loadBatch(limit: Int) -> [ReactionOp] {
        cache = loadAll()
        return Array(cache.prefix(limit))
    }

    func latest(for key: ReactionKey) -> ReactionOp? {
        loadAll().last { $0.key == key }
    }

    func enqueueOrReplaceLatest(for key: ReactionKey, desiredActive: Bool, clientUpdatedAt: Date) {
        var all = loadAll().filter { $0.key != key } // coalesce: keep only newest op for key
        all.append(ReactionOp(id: UUID().uuidString, key: key, desiredActive: desiredActive, clientUpdatedAt: clientUpdatedAt))
        saveAll(all)
    }

    func drop(opId: String) {
        var all = loadAll()
        all.removeAll { $0.id == opId }
        saveAll(all)
    }

    private func saveAll(_ list: [ReactionOp]) {
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: fileURL, options: .atomic)
        }
        cache = list
    }
}

// MARK: - DEBUG Fakes (for unit/UI tests)

#if DEBUG
public final class ReactionRemoteAPIFake: ReactionRemoteAPI {
    public enum Mode { case ok, flaky, conflict }
    private var store: [ReactionKey: RemoteReactionAck] = [:]
    private let mode: Mode
    private var toggle = false

    public init(mode: Mode = .ok) { self.mode = mode }

    public func upsert(idempotencyKey: String, userId: String, itemId: String, type: ReactionType, active: Bool, clientUpdatedAt: Date) async throws -> RemoteReactionAck {
        // Simulate network flip flops
        if mode == .flaky {
            toggle.toggle()
            if toggle { throw URLError(.cannotConnectToHost) }
        }
        let key = ReactionKey(userId: userId, itemId: itemId, type: type)

        // Idempotency: return existing if key matches tuple; ignore repeated writes
        if let existing = store[key], existing.active == active { return existing }

        // Conflict mode: pretend server has a newer write half the time
        if mode == .conflict, Bool.random() {
            let newer = RemoteReactionAck(userId: userId, itemId: itemId, type: type, active: !active, serverUpdatedAt: Date().addingTimeInterval(5))
            store[key] = newer
            return newer
        }

        let ack = RemoteReactionAck(userId: userId, itemId: itemId, type: type, active: active, serverUpdatedAt: Date())
        store[key] = ack
        return ack
    }

    public func fetch(userId: String, itemId: String, type: ReactionType) async throws -> RemoteReactionAck? {
        store[ReactionKey(userId: userId, itemId: itemId, type: type)]
    }
}
#endif


