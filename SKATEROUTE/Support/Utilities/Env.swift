// Support/Utilities/Env.swift
// Centralized environment switches + safe file-system roots and helpers.
// Consistent with CacheManager / SessionLogger / Offline stores.
// Keeps previews/test targets sandboxed, excludes caches from iCloud backup,
// and provides one-liners for secure writes/reads.

import Foundation

enum Env {
    // MARK: - Environment switches

    /// True in SwiftUI previews or the Xcode preview host.
    static var isPreview: Bool {
        let e = ProcessInfo.processInfo.environment
        return e["XCODE_RUNNING_FOR_PREVIEWS"] == "1" || e["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil
    }

    /// True when running XCTest bundles.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// True when running in Simulator.
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// Allow on-disk I/O (disabled for previews to avoid sandbox writes).
    static var allowFileIO: Bool { !isPreview }

    // MARK: - Paths

    /// Root for persistent app data (Application Support). For previews/tests, uses a temp sandbox.
    static func storageRoot() -> URL {
        if isPreview || isRunningTests {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("SKATEROUTE_Sandbox", isDirectory: true)
            ensureDir(url)
            return url
        }

        // Application Support/com.yourcompany.skateroute/SKATEROUTE
        let root = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        let url = root.appendingPathComponent("SKATEROUTE", isDirectory: true)
        ensureDir(url)
        addNoBackupFlag(url)
        return url
    }

    /// Root for ephemeral caches (safe to wipe; excluded from backups).
    static func cachesRoot() -> URL {
        let base = (try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("SKATEROUTE", isDirectory: true)
        ensureDir(url)
        addNoBackupFlag(url)
        return url
    }

    /// Subfolders (created on demand). Keep names stable to avoid migration churn.
    static func logsDir() -> URL {
        let url = storageRoot().appendingPathComponent("Logs", isDirectory: true)
        ensureDir(url); addNoBackupFlag(url); return url
    }

    static func ridesDir() -> URL {
        let url = storageRoot().appendingPathComponent("Rides", isDirectory: true)
        ensureDir(url); addNoBackupFlag(url); return url
    }

    static func offlineRoutesDir() -> URL {
        let url = storageRoot().appendingPathComponent("OfflineRoutes", isDirectory: true)
        ensureDir(url); addNoBackupFlag(url); return url
    }

    static func tilepacksDir() -> URL {
        let url = cachesRoot().appendingPathComponent("Tilepacks", isDirectory: true)
        ensureDir(url); addNoBackupFlag(url); return url
    }

    static func tmpDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SKATEROUTE_Tmp", isDirectory: true)
        ensureDir(url); return url
    }

    // MARK: - File helpers

    /// Ensure a directory exists (idempotent).
    static func ensureDir(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Mark a file/folder as excluded from iCloud/iTunes backups.
    static func addNoBackupFlag(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? (url as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        try? url.setResourceValues(values)
    }

    /// Atomically write data with sensible file protection (when permitted).
    @discardableResult
    static func secureWrite(_ data: Data, to url: URL, options: Data.WritingOptions = [.atomic]) -> Bool {
        guard allowFileIO else { return false }
        do {
            ensureDir(url.deletingLastPathComponent())
            try data.write(to: url, options: options)
            // Prefer completeUntilFirstUserAuthentication so logging still works after reboot-unlock.
            #if os(iOS)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            #endif
            return true
        } catch { return false }
    }

    /// Read data if present (non-throwing).
    static func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// Remove a file or directory tree (non-throwing).
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Rotate a file by renaming existing → .1, keeping up to `keep` versions.
    static func rotateFile(at url: URL, keep: Int = 3) {
        guard allowFileIO, keep > 0 else { return }
        let fm = FileManager.default
        for i in stride(from: keep - 1, through: 1, by: -1) {
            let src = url.appendingPathExtension("\(i)")
            let dst = url.appendingPathExtension("\(i + 1)")
            if fm.fileExists(atPath: src.path) { try? fm.removeItem(at: dst); try? fm.moveItem(at: src, to: dst) }
        }
        let first = url.appendingPathExtension("1")
        if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: first); try? fm.moveItem(at: url, to: first) }
    }

    /// Create a stable file URL for an identifier within a directory (hashing the id to avoid long paths).
    static func hashedFile(in dir: URL, id: String, ext: String) -> URL {
        let h = String(abs(id.hashValue), radix: 36)
        return dir.appendingPathComponent(h).appendingPathExtension(ext)
    }

    // MARK: - Feature flags (process env → boolean)

    /// Pull a boolean feature flag from process environment (e.g., injected by UI Tests).
    static func flag(_ name: String, default defaultValue: Bool = false) -> Bool {
        let e = ProcessInfo.processInfo.environment[name]?.lowercased() ?? ""
        if ["1", "true", "yes", "y", "on"].contains(e) { return true }
        if ["0", "false", "no", "n", "off"].contains(e) { return false }
        return defaultValue
    }

    // MARK: - Disk space (for offline packs diagnostics)

    static func freeDiskBytes() -> Int64 {
        (try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())[.systemFreeSize] as? NSNumber)?.int64Value ?? -1
    }

    static func totalDiskBytes() -> Int64 {
        (try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())[.systemSize] as? NSNumber)?.int64Value ?? -1
    }
}
