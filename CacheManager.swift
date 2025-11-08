// Services/CacheManager.swift
import Foundation

/// `CacheManager` is responsible for managing cached data with support for different caching strategies.
/// It provides thread-safe operations for storing and retrieving data, along with automatic cleanup of expired files.
/// The cache can operate in memory, disk, or hybrid mode, and maintains statistics on cache hits and misses.
public final class CacheManager {
    /// Defines the caching strategy mode.
    public enum CacheType {
        case memory
        case disk
        case hybrid
    }

    /// Tracks cache hit and miss statistics.
    public struct CacheStatistics {
        private(set) var hits: Int = 0
        private(set) var misses: Int = 0

        mutating func recordHit() {
            hits += 1
        }

        mutating func recordMiss() {
            misses += 1
        }

        /// Prints the current cache hit and miss statistics.
        public func printStats() {
            print("Cache Hits: \(hits), Cache Misses: \(misses)")
        }
    }

    public static let shared = CacheManager()

    /// The current cache mode. Defaults to disk.
    public var mode: CacheType = .disk

    /// The expiration interval for cached files, defaulting to 7 days.
    public var expirationInterval: TimeInterval = 7 * 24 * 60 * 60

    private let fm = FileManager.default
    private var stats = CacheStatistics()
    private var memoryCache = [String: Data]()
    private let queue = DispatchQueue(label: "com.cacheManager.queue", attributes: .concurrent)
    private init() {}

    /// Stores data in the cache for the given key.
    /// - Parameters:
    ///   - data: The data to store.
    ///   - key: The key associated with the data.
    /// - Throws: An error if storing to disk fails.
    public func store(_ data: Data, key: String) throws {
        queue.async(flags: .barrier) {
            switch self.mode {
            case .memory:
                self.memoryCache[key] = data
            case .disk:
                do {
                    let url = self.cacheURL(for: key)
                    try self.fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } catch {
                    // Propagate error by rethrowing on main thread
                    DispatchQueue.main.async {
                        fatalError("Failed to store data: \(error)")
                    }
                }
            case .hybrid:
                self.memoryCache[key] = data
                do {
                    let url = self.cacheURL(for: key)
                    try self.fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } catch {
                    DispatchQueue.main.async {
                        fatalError("Failed to store data: \(error)")
                    }
                }
            }
        }
    }

    /// Retrieves cached data for the given key.
    /// - Parameter key: The key associated with the cached data.
    /// - Returns: The cached data if available, otherwise nil.
    public func data(for key: String) -> Data? {
        var result: Data?
        queue.sync {
            switch self.mode {
            case .memory:
                if let data = self.memoryCache[key] {
                    self.stats.recordHit()
                    result = data
                } else {
                    self.stats.recordMiss()
                }
            case .disk:
                let url = self.cacheURL(for: key)
                if let data = try? Data(contentsOf: url) {
                    self.stats.recordHit()
                    result = data
                } else {
                    self.stats.recordMiss()
                }
            case .hybrid:
                if let data = self.memoryCache[key] {
                    self.stats.recordHit()
                    result = data
                } else {
                    let url = self.cacheURL(for: key)
                    if let data = try? Data(contentsOf: url) {
                        self.memoryCache[key] = data
                        self.stats.recordHit()
                        result = data
                    } else {
                        self.stats.recordMiss()
                    }
                }
            }
        }
        return result
    }

    /// Clears cached files older than the expiration interval.
    /// - Throws: An error if file operations fail.
    public func clearExpiredFiles() throws {
        let dir = cacheDirectory()
        let expirationDate = Date().addingTimeInterval(-expirationInterval)
        let contents = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        for url in contents {
            let resourceValues = try url.resourceValues(forKeys: [.contentModificationDateKey])
            if let modificationDate = resourceValues.contentModificationDate, modificationDate < expirationDate {
                try fm.removeItem(at: url)
            }
        }
    }

    /// Clears all cached files if total cache size exceeds the specified limit.
    /// - Parameter keepingLastMB: The maximum cache size in megabytes to keep.
    /// - Throws: An error if file operations fail.
    public func clearOldTiles(keepingLastMB: Int = 500) throws {
        let dir = cacheDirectory()
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let total = contents.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        if total > keepingLastMB * 1_000_000 {
            for url in contents { try? fm.removeItem(at: url) }
        }
    }

    /// Prints the current cache hit and miss statistics.
    public func printStats() {
        queue.sync {
            stats.printStats()
        }
    }

    private func cacheDirectory() -> URL {
        fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MapTiles")
    }
    private func cacheURL(for key: String) -> URL {
        cacheDirectory().appendingPathComponent(key).appendingPathExtension("tile")
    }
}
