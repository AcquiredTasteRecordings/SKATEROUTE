// Services/Offline/OfflineHealthCheck.swift
// Keeps offline packs healthy: periodic checks, LRU eviction under pressure, and repair of corrupt tiles.
// Works with CacheManager & TileFetcher. No secrets. ATT-free. DI-friendly.

import Foundation
import Combine
import CoreLocation
import os.log

// MARK: - DI seams

public protocol CacheBrowsing {
    /// Root directory (e.g., "<AppSupport>/Cache")
    var rootURL: URL { get }
    /// Namespace-relative helper identical to CacheManaging.url(for:createDirs:)
    func url(for keyPath: String, createDirs: Bool) -> URL
}

public protocol TileRefetching {
    /// Re-fetch a batch of tiles for a given provider id. Caller guarantees ToS gating already passed.
    func refetch(providerId: String, tiles: [TileCoord]) async
}

public protocol FreeDiskQuerying {
    func bytesFree() -> Int64
    func bytesTotal() -> Int64
}

// MARK: - Health policy

public struct OfflineHealthPolicy: Equatable, Sendable {
    /// Threshold to start eviction when free space drops below this many bytes.
    public var minFreeBytes: Int64 = 1_000_000_000 // ~1 GB
    /// Target free space to reach after eviction.
    public var targetFreeBytes: Int64 = 1_500_000_000 // ~1.5 GB
    /// Maximum age for expired tile metadata before considered stale.
    public var maxMetaSkewSeconds: TimeInterval = 24 * 3600
    /// Maximum tiles to refetch in one repair batch.
    public var maxRepairBatch: Int = 250
    /// Check cadence in seconds when app is idle.
    public var periodicSeconds: TimeInterval = 600
    public init() {}
}

// MARK: - Public model

public struct OfflineHealthSnapshot: Equatable, Sendable {
    public let checkedAt: Date
    public let freeBytes: Int64
    public let totalBytes: Int64
    public let cacheBytes: Int64
    public let tilesCount: Int
    public let expiredTiles: Int
    public let corruptTiles: Int
    public let evictedFiles: Int
    public let repairedTiles: Int
}

// MARK: - Service

@MainActor
public final class OfflineHealthCheck: ObservableObject {

    public enum State: Equatable { case idle, checking, ready(OfflineHealthSnapshot), error(String) }

    @Published public private(set) var state: State = .idle
    public var snapshotPublisher: AnyPublisher<OfflineHealthSnapshot, Never> { snapshotSubject.eraseToAnyPublisher() }

    // DI
    private let cache: CacheBrowsing
    private let disk: FreeDiskQuerying
    private let refetcher: TileRefetching
    private let policy: OfflineHealthPolicy
    private let log = Logger(subsystem: "com.skateroute", category: "OfflineHealth")

    // Streams
    private let snapshotSubject = PassthroughSubject<OfflineHealthSnapshot, Never>()

    // Scheduling
    private var timer: AnyCancellable?

    public init(cache: CacheBrowsing,
                disk: FreeDiskQuerying = DefaultDiskQuery(),
                refetcher: TileRefetching,
                policy: OfflineHealthPolicy = .init()) {
        self.cache = cache
        self.disk = disk
        self.refetcher = refetcher
        self.policy = policy
    }

    // MARK: Lifecycle hooks

    /// Call on app start.
    public func onAppStart() {
        Task { await runOnce(reason: "app_start") }
        startPeriodic()
    }

    /// Call when app becomes idle (e.g., after nav).
    public func onIdle() {
        Task { await runOnce(reason: "idle") }
    }

    /// Manual trigger.
    public func runNow() {
        Task { await runOnce(reason: "manual") }
    }

    // MARK: Core check

    private func startPeriodic() {
        timer?.cancel()
        guard policy.periodicSeconds > 0 else { return }
        timer = Timer.publish(every: policy.periodicSeconds, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                Task { await self?.runOnce(reason: "periodic") }
            }
    }

    private func tilesRoot() -> URL {
        cache.rootURL.appendingPathComponent("Tiles", isDirectory: true)
    }

    private struct TileFile {
        let url: URL
        let providerId: String
        let z: Int
        let x: Int
        let y: Int
        let metaURL: URL
        let size: Int64
        let atime: Date
        let mtime: Date
    }

    private func enumerateTiles() -> [TileFile] {
        let root = tilesRoot()
        var out: [TileFile] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentAccessDateKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return out }
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "png" || url.pathExtension.lowercased() == "jpg" || url.pathExtension.lowercased() == "pbf" else { continue }
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            // Expect "<provider>/<z>/<x>/<y>.<ext>"
            let comps = rel.split(separator: "/")
            guard comps.count == 4,
                  let z = Int(comps[1]),
                  let x = Int(comps[2]),
                  let yPart = comps[3].split(separator: ".").first,
                  let y = Int(yPart) else { continue }
            let providerId = String(comps[0])
            let metaURL = url.appendingPathExtension("meta")
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let atime = values?.contentAccessDate ?? (values?.contentModificationDate ?? Date.distantPast)
            let mtime = values?.contentModificationDate ?? atime
            out.append(TileFile(url: url, providerId: providerId, z: z, x: x, y: y, metaURL: metaURL, size: size, atime: atime, mtime: mtime))
        }
        return out
    }

    private func parseMeta(_ url: URL) -> Meta? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    private struct Meta: Codable {
        let fetchedAt: Date
        let etag: String?
        let expiresAt: Date
    }

    private func fileSizeOfFolder(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            if let s = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               (s.isRegularFile ?? false) {
                total += Int64(s.fileSize ?? 0)
            }
        }
        return total
    }

    private func shouldEvict(_ free: Int64) -> Bool { free < policy.minFreeBytes }

    private func targetEvictBytes(currentFree: Int64) -> Int64 {
        max(0, policy.targetFreeBytes - currentFree)
    }

    // MARK: Run

    private func runOnce(reason: String) async {
        state = .checking
        let free = disk.bytesFree()
        let total = disk.bytesTotal()

        // Scan cache
        let all = enumerateTiles()
        let cacheBytes = fileSizeOfFolder(tilesRoot())

        // Integrity & expiry
        var corrupt: [TileFile] = []
        var expired: [TileFile] = []
        let now = Date()
        for t in all {
            if (try? Data(contentsOf: t.url)) == nil || t.size == 0 {
                corrupt.append(t)
                continue
            }
            if let m = parseMeta(t.metaURL) {
                if now >= m.expiresAt || now.timeIntervalSince(m.fetchedAt) > policy.maxMetaSkewSeconds {
                    expired.append(t)
                }
            } else {
                // Missing meta is treated as expired
                expired.append(t)
            }
        }

        // Evict if needed using LRU order by atime/mtime
        var evicted = 0
        var repaired = 0
        var freeNow = free

        if shouldEvict(freeNow) {
            let need = targetEvictBytes(currentFree: freeNow)
            var freed: Int64 = 0
            let toEvict = all.sorted { $0.atime < $1.atime } // LRU
            for f in toEvict {
                do {
                    try FileManager.default.removeItem(at: f.url)
                    try? FileManager.default.removeItem(at: f.metaURL)
                    freed += f.size
                    evicted += 1
                    if freed >= need { break }
                } catch {
                    // ignore & continue
                }
            }
            freeNow += freed
        }

        // Repair corrupt/expired segments in small batches, grouped by provider id
        var byProvider: [String: [TileCoord]] = [:]
        for t in (corrupt + expired).prefix(policy.maxRepairBatch) {
            let coord = TileCoord(z: t.z, x: t.x, y: t.y)
            byProvider[t.providerId, default: []].append(coord)
        }
        for (pid, coords) in byProvider {
            await refetcher.refetch(providerId: pid, tiles: coords)
            repaired += coords.count
        }

        let snap = OfflineHealthSnapshot(checkedAt: Date(),
                                         freeBytes: freeNow,
                                         totalBytes: total,
                                         cacheBytes: cacheBytes,
                                         tilesCount: all.count,
                                         expiredTiles: expired.count,
                                         corruptTiles: corrupt.count,
                                         evictedFiles: evicted,
                                         repairedTiles: repaired)
        state = .ready(snap)
        snapshotSubject.send(snap)

        log.notice("Offline health (\(reason, privacy: .public)): free=\(freeNow, privacy: .public) cache=\(cacheBytes, privacy: .public) tiles=\(all.count, privacy: .public) evicted=\(evicted, privacy: .public) repaired=\(repaired, privacy: .public)")
    }
}

// MARK: - Default disk query

public struct DefaultDiskQuery: FreeDiskQuerying {
    public init() {}
    public func bytesFree() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory() as String)
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
    public func bytesTotal() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory() as String)
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey])
        return Int64(values?.volumeTotalCapacity ?? 0)
    }
}

// MARK: - DEBUG fakes (tests)

#if DEBUG
public final class CacheBrowserFake: CacheBrowsing {
    public let rootURL: URL
    public init(root: URL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("offline-tests", isDirectory: true)) {
        self.rootURL = root
        try? FileManager.default.createDirectory(at: rootURL.appendingPathComponent("Tiles", isDirectory: true), withIntermediateDirectories: true)
    }
    public func url(for keyPath: String, createDirs: Bool) -> URL {
        let url = rootURL.appendingPathComponent(keyPath)
        if createDirs { try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        return url
    }
    // Helpers to seed files
    public func seedTile(provider: String, z: Int, x: Int, y: Int, bytes: Int = 2048, age: TimeInterval = 3600, expired: Bool = false, missingMeta: Bool = false) {
        let tilePath = "Tiles/\(provider)/\(z)/\(x)/\(y).png"
        let metaPath = tilePath + ".meta"
        let tURL = url(for: tilePath, createDirs: true)
        let mURL = url(for: metaPath, createDirs: true)
        try? Data(repeating: 0xAB, count: bytes).write(to: tURL)
        let fetchedAt = Date().addingTimeInterval(-age)
        let exp = Date().addingTimeInterval(expired ? -3600 : 3600)
        let meta = OfflineHealthCheck.Meta(fetchedAt: fetchedAt, etag: "e", expiresAt: exp)
        if !missingMeta, let md = try? JSONEncoder().encode(meta) { try? md.write(to: mURL) }
        // Touch access time by reading file (to simulate LRU)
        _ = try? Data(contentsOf: tURL)
    }
}

public final class TileRefetcherSpy: TileRefetching {
    public private(set) var calls: [(String, [TileCoord])] = []
    public init() {}
    public func refetch(providerId: String, tiles: [TileCoord]) async { calls.append((providerId, tiles)) }
}
#endif

// MARK: - Integration notes
// • AppDI: construct OfflineHealthCheck with CacheManager (expose a CacheBrowsing-compliant shim), DefaultDiskQuery(), and a TileRefetcher
//   that bridges to your TileFetcher (group tiles by provider → plan.execute for those coords).
// • App start: call onAppStart(). After long nav sessions or when device cools down, call onIdle().
// • DiagnosticsView: subscribe to snapshotPublisher; show free space, cache bytes, tiles count, and last actions (evicted/repaired).
// • Eviction is conservative, LRU-based, only when under pressure. Repair is capped to small batches to protect battery.

// MARK: - Test plan (unit)
//
// 1) Simulated disk low eviction:
//    - Create CacheBrowserFake and seed 500 tiles (~1MB each). Stub FreeDiskQuerying to return freeBytes < minFreeBytes.
//    - Run onAppStart(); expect evictedFiles > 0 and post-state .ready with freeBytes >= targetFreeBytes.
//
// 2) Corrupt file restore:
//    - Seed tiles with one zero-byte file and a valid meta; run runNow(); expect repairedTiles == 1 with spy capturing refetch call.
//
// 3) Expired meta repair:
//    - Seed tiles with expiresAt in the past; run runNow(); expect repairedTiles equals expired count up to maxRepairBatch.
//
// 4) Missing meta treated as expired:
//    - Seed tile without .meta; run; expect included in repair set.
//
// 5) LRU ordering respected:
//    - Seed A (old atime) and B (fresh atime); force eviction; ensure A is removed first.
//
// 6) Periodic scheduling:
//    - Set periodicSeconds small; assert runOnce is invoked repeatedly (spy with a counter).


