// Services/SegmentStore.swift
import Foundation
import MapKit

/// Stores per-segment quality / roughness info that we learn from riders.
/// A “segment” here is usually “one step of a MapKit route” (i.e. step index).
/// We keep it VERY simple: key = stepIndex (Int), value = metrics + metadata.
///
/// Features:
/// - in-memory cache for speed
/// - JSON on disk for persistence
/// - freshness with auto-decay (old data gets less trust)
/// - thread-safe via a serial queue
public final class SegmentStore {

    // MARK: - Singleton

    public static let shared = SegmentStore()

    // Preview-safe file I/O shim (local to SegmentStore)
    private enum Env {
        static var allowFileIO: Bool {
            #if DEBUG
            // When SwiftUI previews run, XCODE_RUNNING_FOR_PREVIEWS=1; avoid touching Documents.
            let previews = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
            return !previews
            #else
            return true
            #endif
        }
        static func storageRoot() -> URL {
            // App's Documents directory
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        }
        static func ensureDir(_ url: URL) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - Types

    /// What we know about one segment.
    private struct SegmentData: Codable {
        var quality: Double        // 0…1 or any score you decide
        var roughness: Double      // RMS-ish value we derived
        var lastUpdated: Date
        var freshnessScore: Double // 0…1 (1 = fresh, 0 = stale)
    }

    // MARK: - Storage

    /// In-memory
    private var segments: [Int: SegmentData] = [:]

    /// All I/O happens on this queue to keep it thread-safe
    private let queue = DispatchQueue(label: "com.skateroute.segmentstore")

    /// Where we write the JSON
    private let fileURL: URL

    // MARK: - Init

    private init(filename: String = "segment_store.json") {
        // Documents dir
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.fileURL = docs.appendingPathComponent(filename)

        // Load what we had
        self.loadFromDisk()
        // Decay anything too old
        self.applyDecayToStaleEntries()
    }

    // MARK: - Public API

    /// Flushes the current segment data for a given stepId to a newline-delimited JSON file in Documents/Segments.
    /// This is preview-safe (no-op when running SwiftUI previews).
    public func flush(stepId: String) {
        guard Env.allowFileIO else { return }                // hard gate for previews
        let root = Env.storageRoot()                          // safe root
        let dir  = root.appendingPathComponent("Segments", isDirectory: true)
        Env.ensureDir(dir)

        let fileURL = dir.appendingPathComponent("\(stepId).ndjson")

        // Capture a stable snapshot of the segment row on our queue
        var dataToWrite: Data?
        queue.sync {
            // Map string stepId to the integer key we use internally
            let idx: Int
            if let n = Int(stepId) {
                idx = n
            } else {
                idx = abs(stepId.hashValue % Int(Int32.max))
            }

            if let seg = self.segments[idx] {
                struct Row: Codable {
                    let stepId: String
                    let quality: Double
                    let roughness: Double
                    let freshness: Double
                    let updatedAt: String
                }
                let iso = ISO8601DateFormatter()
                let row = Row(stepId: stepId,
                              quality: seg.quality,
                              roughness: seg.roughness,
                              freshness: seg.freshnessScore,
                              updatedAt: iso.string(from: seg.lastUpdated))
                let enc = JSONEncoder()
                if let json = try? enc.encode(row) {
                    var line = Data()
                    line.append(json)
                    line.append(0x0A) // newline for NDJSON
                    dataToWrite = line
                }
            }
        }

        guard let data = dataToWrite else { return }

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let fh = try FileHandle(forWritingTo: fileURL)
                defer { try? fh.close() }                     // always close
                try fh.seekToEnd()
                try fh.write(contentsOf: data)
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
        } catch {
            // Optionally log via os.Logger; intentionally silent in release to avoid console noise
        }
    }

    // MARK: - Helpers (IDs & convenience accessors)

    /// Builds a stable step identifier for a route+step pair.
    /// Currently we key the store by step index only, so this returns the `stepIndex`.
    /// Keeping this helper lets call sites evolve without changing their signatures.
    @inlinable
    public func makeStepId(route: MKRoute, stepIndex: Int) -> Int { stepIndex }

    /// Convenience getter for just roughness if a caller doesn't need full tuple.
    public func roughness(forStepIndex stepIndex: Int) -> Double? {
        var value: Double?
        queue.sync { value = segments[stepIndex]?.roughness }
        return value
    }

    /// Convenience getter for quality.
    public func quality(forStepIndex stepIndex: Int) -> Double? {
        var value: Double?
        queue.sync { value = segments[stepIndex]?.quality }
        return value
    }

    /// Update only the roughness while preserving prior quality (defaults to 0.5 if unknown).
    public func setRoughness(_ roughness: Double, forStepIndex stepIndex: Int) {
        let currentQuality: Double = {
            var q: Double?
            queue.sync { q = segments[stepIndex]?.quality }
            return q ?? 0.5
        }()
        writeSegment(at: stepIndex, quality: currentQuality, roughness: roughness)
    }

    /// Read all info for a step index.
    /// - Returns: (quality, roughness, lastUpdated, freshnessScore) or nil if we don't know this segment yet.
    public func readSegment(at stepIndex: Int) -> (quality: Double, roughness: Double, lastUpdated: Date, freshnessScore: Double)? {
        var result: (Double, Double, Date, Double)?
        queue.sync {
            if let s = segments[stepIndex] {
                result = (s.quality, s.roughness, s.lastUpdated, s.freshnessScore)
            }
        }
        return result
    }

    /// Write/update a segment with new smoothness data.
    /// This is what you call from Recorder/Matcher when the rider skates over a step.
    public func writeSegment(at stepIndex: Int, quality: Double, roughness: Double) {
        let now = Date()
        let newData = SegmentData(
            quality: quality,
            roughness: roughness,
            lastUpdated: now,
            freshnessScore: 1.0
        )

        queue.async {
            self.segments[stepIndex] = newData
            self.saveToDisk()
            
        }
    }

    /// Let other parts of the app lower/raise freshness.
    public func updateFreshness(at stepIndex: Int, freshnessScore: Double) {
        queue.async {
            guard var data = self.segments[stepIndex] else { return }
            data.freshnessScore = max(0, min(1, freshnessScore))
            data.lastUpdated = Date()
            self.segments[stepIndex] = data
            self.saveToDisk()
        }
    }

    /// Export everything we have to disk (overwrites the same file).
    /// You can later find it in the app’s Documents folder via Xcode → Devices → Download container.
    public func exportToJSON() {
        queue.async {
            do {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try enc.encode(self.segments)
                try data.write(to: self.fileURL, options: .atomic)
                print("📦 SegmentStore: exported to \(self.fileURL.path)")
            } catch {
                print("⚠️ SegmentStore: export failed: \(error)")
            }
        }
    }

    /// Clear everything (useful for debugging)
    public func clear() {
        queue.async {
            self.segments.removeAll()
            self.saveToDisk()
        }
    }

    // MARK: - Private

    private func loadFromDisk() {
        queue.async {
            guard FileManager.default.fileExists(atPath: self.fileURL.path) else { return }
            do {
                let data = try Data(contentsOf: self.fileURL)
                let dec = JSONDecoder()
                let decoded = try dec.decode([Int: SegmentData].self, from: data)
                self.segments = decoded
                // print("📥 SegmentStore: loaded \(decoded.count) segments from disk")
            } catch {
                print("⚠️ SegmentStore: failed to load from disk: \(error)")
            }
        }
    }

    private func saveToDisk() {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(self.segments)
            try data.write(to: self.fileURL, options: .atomic)
        } catch {
            print("⚠️ SegmentStore: failed to save: \(error)")
        }
    }

    /// Any entry older than 7 days gets its freshness reduced.
    private func applyDecayToStaleEntries() {
        let now = Date()
        let sevenDays: TimeInterval = 7 * 24 * 60 * 60

        queue.async {
            var changed = false
            for (idx, seg) in self.segments {
                let age = now.timeIntervalSince(seg.lastUpdated)
                guard age > sevenDays else { continue }

                // decay 0.1 per day past 7 days, but never below 0
                let daysPast = (age - sevenDays) / (24 * 60 * 60)
                let decay = min(seg.freshnessScore, daysPast * 0.1)
                let newFreshness = max(seg.freshnessScore - decay, 0)

                if newFreshness != seg.freshnessScore {
                    var updated = seg
                    updated.freshnessScore = newFreshness
                    self.segments[idx] = updated
                    changed = true
                }
            }
            if changed {
                self.saveToDisk()
            }
        }
    }
}
// MARK: - Compatibility shim for older call sites
extension SegmentStore {
    /// Alias for older code paths that called `update(stepId:with:)`.
    /// We currently key the store by integer step index. If `stepId` is not an Int,
    /// we fallback to a stable hash so the call site compiles and data still persists.
    public func update(stepId: String, with roughnessRMS: Double) {
        if let idx = Int(stepId) {
            setRoughness(roughnessRMS, forStepIndex: idx)
        } else {
            let idx = abs(stepId.hashValue % Int(Int32.max))
            setRoughness(roughnessRMS, forStepIndex: idx)
        }
    }
}

// MARK: - Additional back-compat & string stepId helpers
extension SegmentStore {
    /// Legacy alias some call sites still use.
    /// Routes through the `update(stepId:with:)` shim.
    public func appendRoughnessSample(stepId: String, value: Double) {
        update(stepId: stepId, with: value)
    }

    /// Read-only helpers for string step identifiers.
    public func roughness(forStepId stepId: String) -> Double? {
        if let idx = Int(stepId) {
            return roughness(forStepIndex: idx)
        } else {
            let idx = abs(stepId.hashValue % Int(Int32.max))
            return roughness(forStepIndex: idx)
        }
    }

    public func quality(forStepId stepId: String) -> Double? {
        if let idx = Int(stepId) {
            return quality(forStepIndex: idx)
        } else {
            let idx = abs(stepId.hashValue % Int(Int32.max))
            return quality(forStepIndex: idx)
        }
    }
}
