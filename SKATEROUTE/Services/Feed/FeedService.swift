// Services/Feed/FeedService.swift
// Mixed feed (videos/spots/routes) with local cache + remote pagination.
// Time-ordered by createdAt, opaque “since” tokens, duplicate suppression.
// Swift-only, no secrets, ATT-free.

import Foundation
import Combine
import os.log

// MARK: - Contracts

/// Your app-level FeedItem model (Codable) should live in Models/FeedItem.swift and conform to this.
public protocol FeedItemProtocol: Codable, Identifiable, Hashable {
    associatedtype ID: Hashable & Codable
    var id: ID { get }
    var createdAt: Date { get }     // authoritative ordering
    var kind: Kind { get }          // .video / .spot / .route, as per your spec

    enum Kind: String, Codable, CaseIterable {
        case video, spot, route
    }
}

// Declare your concrete model elsewhere:
// public struct FeedItem: FeedItemProtocol { ... }

public protocol FeedRemoteAPI {
    /// Fetch a page strictly newer than `since` (server-defined opaque token or nil for first page).
    /// Must return items in descending createdAt (newest first) and the next `since` token,
    /// or nil token if end-of-feed.
    func fetchPage(since: String?, pageSize: Int) async throws -> (items: [any FeedItemProtocol], nextSince: String?)
}

// MARK: - FeedService

@MainActor
public final class FeedService<Item: FeedItemProtocol>: ObservableObject {

    public enum State: Equatable {
        case idle
        case loading
        case ready(endReached: Bool)
        case error(String)
    }

    // Public stream for UI (infinite scroll)
    @Published public private(set) var state: State = .idle
    @Published public private(set) var items: [Item] = []
    public var feedPublisher: AnyPublisher<[Item], Never> { $items.eraseToAnyPublisher() }

    // Config
    public struct Config: Equatable {
        public var pageSize: Int = 20
        public var cacheLimit: Int = 120
        public var cacheFileName: String = "feed-cache.json"
        public init() {}
    }

    private let log = Logger(subsystem: "com.skateroute", category: "FeedService")
    private let config: Config
    private let remote: FeedRemoteAPI
    private let cache: FeedCache<Item>

    // Pagination state
    private var sinceToken: String?
    private var endReached = false

    // Dedupe set
    private var seen: Set<Item.ID> = []

    // Concurrency guard
    private var isLoading = false

    // MARK: Init

    public init(remote: FeedRemoteAPI, config: Config = .init()) {
        self.remote = remote
        self.config = config
        self.cache = FeedCache<Item>(fileName: config.cacheFileName, limit: config.cacheLimit)
        // Fast cold-start from disk cache
        if let snapshot = cache.loadSnapshot() {
            self.items = snapshot.items
            self.sinceToken = snapshot.since
            self.endReached = snapshot.endReached
            self.seen = Set(snapshot.items.map(\.id))
            self.state = .ready(endReached: snapshot.endReached)
        } else {
            self.state = .idle
        }
    }

    // MARK: API

    /// Resets the feed and loads the first page from remote (keeping cache for fallback).
    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        state = .loading
        sinceToken = nil
        endReached = false
        seen.removeAll()

        do {
            // Network page 1
            let (fetched, next) = try await remote.fetchPage(since: nil, pageSize: config.pageSize)
            let cleaned = sanitizeAndDedupe(fetched)
            items = cleaned
            sinceToken = next
            endReached = (next == nil)
            state = .ready(endReached: endReached)
            cache.save(items: items, since: sinceToken, endReached: endReached)
        } catch {
            // On hard error keep existing cache; only update state
            state = .error("Couldn’t refresh feed")
            log.error("Feed refresh failed: \(error.localizedDescription, privacy: .public)")
        }
        isLoading = false
    }

    /// Loads the next page if available; safe to call repeatedly during scroll.
    public func loadNextPage() async {
        guard !isLoading, !endReached else { return }
        isLoading = true
        state = .loading

        do {
            let (fetched, next) = try await remote.fetchPage(since: sinceToken, pageSize: config.pageSize)
            let cleaned = sanitizeAndDedupe(fetched)
            if cleaned.isEmpty, next == sinceToken || next == nil {
                // Defensive: no progress → mark end
                endReached = true
                sinceToken = nil
            } else {
                items.append(contentsOf: cleaned)
                items.sort { $0.createdAt > $1.createdAt }
                items = Array(items.prefix(config.cacheLimit)) // cap memory/cache growth
                sinceToken = next
                endReached = (next == nil)
            }
            state = .ready(endReached: endReached)
            cache.save(items: items, since: sinceToken, endReached: endReached)
        } catch {
            // Soft failure; keep current items, allow retry
            state = .error("Couldn’t load more")
            log.error("Feed page failed: \(error.localizedDescription, privacy: .public)")
        }

        isLoading = false
    }

    /// Force local cache write (DiagnosticsView) and return a snapshot.
    @discardableResult
    public func snapshot() -> FeedCache<Item>.Snapshot {
        let snap = FeedCache<Item>.Snapshot(items: items, since: sinceToken, endReached: endReached)
        cache.saveSnapshot(snap)
        return snap
    }

    /// Clears cache and memory feed; next call to refresh/load will re-fill.
    public func purge() {
        items.removeAll(keepingCapacity: false)
        sinceToken = nil
        endReached = false
        seen.removeAll()
        cache.clear()
        state = .idle
    }

    // MARK: - Helpers

    private func sanitizeAndDedupe(_ incoming: [any FeedItemProtocol]) -> [Item] {
        // (1) Filter to Item (when remote returns type-erased items)
        let casted: [Item] = incoming.compactMap { $0 as? Item }
        // (2) Drop duplicates already seen
        let fresh = casted.filter { !seen.contains($0.id) }
        // (3) Update seen set
        fresh.forEach { seen.insert($0.id) }
        // (4) Sort by createdAt DESC just in case
        return fresh.sorted { $0.createdAt > $1.createdAt }
    }
}

// MARK: - Cache (disk JSON)

fileprivate final class FeedCache<Item: FeedItemProtocol> {
    struct Snapshot: Codable {
        var items: [Item]
        var since: String?
        var endReached: Bool
    }

    private let fileURL: URL
    private let limit: Int
    private let fm = FileManager.default

    init(fileName: String, limit: Int) {
        self.limit = max(20, limit)
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("FeedCache", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent(fileName)
    }

    func loadSnapshot() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    func save(items: [Item], since: String?, endReached: Bool) {
        let snap = Snapshot(items: Array(items.prefix(limit)), since: since, endReached: endReached)
        saveSnapshot(snap)
    }

    func saveSnapshot(_ snap: Snapshot) {
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func clear() { try? fm.removeItem(at: fileURL) }
}

// MARK: - DEBUG fakes for tests

#if DEBUG
public final class FeedRemoteAPIFake<Item: FeedItemProtocol>: FeedRemoteAPI {
    private var pages: [[Item]]
    private var tokens: [String?]
    private var idx = 0

    /// pages: array of pages newest→older; tokens: opaque next tokens per page
    public init(pages: [[Item]], tokens: [String?]) {
        self.pages = pages; self.tokens = tokens
    }

    public func fetchPage(since: String?, pageSize: Int) async throws -> (items: [any FeedItemProtocol], nextSince: String?) {
        // emulate network and token flow
        try await Task.sleep(nanoseconds: 80_000_000)
        guard idx < pages.count else { return ([], nil) }
        let out = pages[idx]
        let token = tokens[idx]
        idx += 1
        return (out, token)
    }
}
#endif


