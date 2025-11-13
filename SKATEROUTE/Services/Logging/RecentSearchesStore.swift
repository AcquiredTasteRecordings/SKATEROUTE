// Services/RecentSearchesStore.swift
// Local, privacy-first MRU for search. De-dupes by normalized string, decays by recency.
// Optional Spotlight indexing via a pluggable adapter. No tracking. No 3P SDKs.

import Foundation
import Combine
import os.log

// MARK: - DI seams

public protocol SearchIndexing {
    func index(_ entries: [RecentSearchesStore.Entry]) async
    func deleteAll() async
}

public struct RecentSearchesConfig: Equatable {
    public var maxEntries: Int = 50
    public var minPrefixForSuggestions: Int = 1
    public var decayHalfLifeDays: Double = 21        // recency decay (higher = “stickier” history)
    public var enableSpotlightIndexing: Bool = false // off by default
    public init() {}
}

// MARK: - Store

@MainActor
public final class RecentSearchesStore: ObservableObject {

    // Public read model
    public struct Entry: Codable, Hashable, Identifiable {
        public let id: String                // normalized
        public let original: String          // as typed last time
        public let normalized: String
        public let lastUsedAt: Date
        public let uses: Int                 // number of times user chose this
        public init(id: String, original: String, normalized: String, lastUsedAt: Date, uses: Int) {
            self.id = id; self.original = original; self.normalized = normalized; self.lastUsedAt = lastUsedAt; self.uses = uses
        }
    }

    public enum State: Equatable { case idle, ready, error(String) }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var entries: [Entry] = []

    public var entriesPublisher: AnyPublisher<[Entry], Never> { $entries.eraseToAnyPublisher() }

    // DI
    private let indexer: SearchIndexing?
    private(set) var config: RecentSearchesConfig
    private let log = Logger(subsystem: "com.skateroute", category: "RecentSearches")

    // Persistence
    private let fileURL: URL
    private let fm = FileManager.default

    // MARK: Init

    public init(config: RecentSearchesConfig = .init(), indexer: SearchIndexing? = nil) {
        self.config = config
        self.indexer = indexer

        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Search", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("recent.json")

        self.entries = load()
        self.state = .ready

        Task { await reindexIfNeeded() }
    }

    // MARK: Public API

    /// Record a query the user executed. De-dupes by normalized form and bumps recency/uses.
    public func record(query raw: String, at date: Date = Date()) {
        let norm = Self.normalize(raw)
        guard !norm.isEmpty else { return }

        var map = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        if var existing = map[norm] {
            let updated = Entry(id: norm,
                                original: raw, // keep latest surface form
                                normalized: norm,
                                lastUsedAt: date,
                                uses: min(existing.uses + 1, Int.max))
            map[norm] = updated
        } else {
            map[norm] = Entry(id: norm, original: raw, normalized: norm, lastUsedAt: date, uses: 1)
        }

        entries = Self.rankAndTrim(Array(map.values), now: date, cfg: config)
        save(entries)
        Task { await reindexIfNeeded() }
    }

    /// Return ranked suggestions filtered by prefix (case/diacritic-insensitive).
    public func suggestions(prefix raw: String, limit: Int = 8, now: Date = Date()) -> [Entry] {
        let norm = Self.normalize(raw)
        guard norm.count >= config.minPrefixForSuggestions else { return [] }
        let filtered = entries.filter { $0.normalized.hasPrefix(norm) }
        return Self.rank(filtered, now: now, cfg: config).prefix(limit).map { $0 }
    }

    /// Remove a specific query (by raw or normalized).
    public func remove(_ rawOrNormalized: String) {
        let key = Self.normalize(rawOrNormalized)
        let after = entries.filter { $0.id != key }
        guard after.count != entries.count else { return }
        entries = after
        save(entries)
        Task { await reindexIfNeeded() }
    }

    /// Clear everything.
    public func clear() {
        entries.removeAll(keepingCapacity: false)
        save(entries)
        Task { await indexer?.deleteAll() }
    }

    /// Update config and re-rank entries; persists but does not reindex unless Spotlight state changed.
    public func updateConfig(_ new: RecentSearchesConfig) {
        let oldIndexFlag = config.enableSpotlightIndexing
        config = new
        entries = Self.rankAndTrim(entries, now: Date(), cfg: config)
        save(entries)
        if oldIndexFlag != new.enableSpotlightIndexing {
            Task { await reindexIfNeeded() }
        }
    }

    // MARK: Internals

    private func reindexIfNeeded() async {
        guard config.enableSpotlightIndexing, let indexer else { return }
        await indexer.index(entries)
    }

    private func load() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            log.error("RecentSearches load failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func save(_ list: [Entry]) {
        do {
            let data = try JSONEncoder().encode(list)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("RecentSearches save failed: \(error.localizedDescription, privacy: .public)")
            state = .error("Couldn’t write recent searches")
        }
    }

    // MARK: Ranking / Decay

    private static func rankAndTrim(_ list: [Entry], now: Date, cfg: RecentSearchesConfig) -> [Entry] {
        let ranked = rank(list, now: now, cfg: cfg)
        return Array(ranked.prefix(cfg.maxEntries))
    }

    private static func rank(_ list: [Entry], now: Date, cfg: RecentSearchesConfig) -> [Entry] {
        // Score = uses * exp(-age/τ). τ = halfLife / ln(2)
        let tau = (cfg.decayHalfLifeDays * 86_400) / log(2.0)
        return list.sorted { a, b in
            let sa = score(for: a, now: now, tau: tau)
            let sb = score(for: b, now: now, tau: tau)
            if sa == sb { return a.lastUsedAt > b.lastUsedAt } // tie-breaker
            return sa > sb
        }
    }

    private static func score(for e: Entry, now: Date, tau: Double) -> Double {
        let age = now.timeIntervalSince(e.lastUsedAt)
        let decay = exp(-age / tau)
        return Double(max(1, e.uses)) * decay
    }

    // MARK: Normalization

    /// Lowercase, diacritic-insensitive, trimmed, single-spaced.
    public static func normalize(_ raw: String) -> String {
        // Strip leading/trailing whitespace/newlines, collapse interior whitespace to single spaces.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let folded = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let singleSpaced = folded.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return singleSpaced.lowercased()
    }
}

// MARK: - Optional Spotlight indexer

#if canImport(CoreSpotlight) && canImport(MobileCoreServices)
import CoreSpotlight
import UniformTypeIdentifiers

public final class SpotlightSearchIndexer: SearchIndexing {
    public init() {}

    public func index(_ entries: [RecentSearchesStore.Entry]) async {
        let items: [CSSearchableItem] = entries.map { e in
            let attr = CSSearchableItemAttributeSet(contentType: UTType.text)
            attr.title = e.original
            attr.contentDescription = e.normalized
            attr.keywords = e.original.split(separator: " ").map(String.init)
            return CSSearchableItem(uniqueIdentifier: "recent:\(e.id)",
                                    domainIdentifier: "com.skateroute.search",
                                    attributeSet: attr)
        }
        await withCheckedContinuation { cont in
            CSSearchableIndex.default().indexSearchableItems(items) { _ in cont.resume() }
        }
    }

    public func deleteAll() async {
        await withCheckedContinuation { cont in
            CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: ["com.skateroute.search"]) { _ in cont.resume() }
        }
    }
}
#else
public final class SpotlightSearchIndexer: SearchIndexing {
    public init() {}
    public func index(_ entries: [RecentSearchesStore.Entry]) async {}
    public func deleteAll() async {}
}
#endif

// MARK: - DEBUG Fakes (for tests)

#if DEBUG
public final class NullSearchIndexer: SearchIndexing {
    public init() {}
    public func index(_ entries: [RecentSearchesStore.Entry]) async {}
    public func deleteAll() async {}
}
#endif

// MARK: - Lightweight tests you should add (summary)
// • De-dupe: record(" Park  Plaza ") then record("park plaza") → entries.count == 1; uses increments; original updates to latest casing.
// • Decay: seed two entries with different lastUsedAt; assert rank(order) changes as ages cross under configured half-life.
// • Suggestions: with minPrefix=2, suggestions("p") == []; suggestions("pa") returns normalized prefix matches, ordered by score.
// • Remove & clear: remove("Park Plaza") deletes regardless of casing/spaces; clear() yields empty list and calls indexer.deleteAll() when enabled.
// • Spotlight: with enableSpotlightIndexing=true and SpotlightSearchIndexer injected, index() is called with current entries after record()/remove()/clear().


