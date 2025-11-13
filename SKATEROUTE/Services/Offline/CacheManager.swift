// Services/Offline/CacheManager.swift
// Lightweight disk cache manager for offline tiles, route manifests, and diagnostics.
// Thread-safe via a serial queue. No secrets or background uploads.

import Foundation

/// Canonical cache facade used by OfflineTileManager, OfflineRouteStore, diagnostics, and tests.
@MainActor
public final class CacheManager: CacheManaging {
    public static let shared = CacheManager()

    private let fm: FileManager
    private let root: URL
    private let queue = DispatchQueue(label: "com.skateroute.cachemanager", qos: .utility)

    private init(fileManager: FileManager = .default) {
        self.fm = fileManager
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.root = base.appendingPathComponent("SkateRouteCache", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - CacheManaging

    public func url(for keyPath: String, createDirs: Bool = false) -> URL {
        let sanitized = keyPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let destination = root.appendingPathComponent(sanitized)
        if createDirs {
            let dir = destination.deletingLastPathComponent()
            queue.sync {
                if !fm.fileExists(atPath: dir.path) {
                    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                }
            }
        }
        return destination
    }

    public func exists(_ keyPath: String) -> Bool {
        let path = url(for: keyPath).path
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    public func write(_ data: Data, to keyPath: String) throws {
        let destination = url(for: keyPath, createDirs: true)
        try queue.sync {
            try data.write(to: destination, options: .atomic)
        }
    }

    public func read(_ keyPath: String) -> Data? {
        let source = url(for: keyPath)
        return queue.sync {
            try? Data(contentsOf: source)
        }
    }

    public func remove(_ keyPath: String) throws {
        let target = url(for: keyPath)
        try queue.sync {
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
        }
    }
}

// MARK: - Helpers for diagnostics
public extension CacheManager {
    func directorySizeBytes() -> Int64 {
        queue.sync {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
            var total: Int64 = 0
            for case let url as URL in enumerator {
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += Int64(size)
                }
            }
            return total
        }
    }

    func reset() {
        queue.sync {
            try? fm.removeItem(at: root)
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }
}

