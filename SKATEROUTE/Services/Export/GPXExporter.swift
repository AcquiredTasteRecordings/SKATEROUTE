// Services/Export/GPXExporter.swift
// Ethical data portability: export SessionLogger NDJSON rides to GPX 1.1 and GeoJSON (RFC 7946).
// • Privacy-first: optional "home fuzzing" (trim or jitter first/last N meters/seconds), EXIF-free files.
// • Tolerant NDJSON parser (accepts multiple shapes). No PII, no device identifiers.
// • Outputs either Data or a temporary file URL ready for a ShareSheet.
// • Deterministic ISO8601 timestamps, WGS84 coordinates. Checksums embedded as comments/props.
//
// Integration:
//   - Reads /Application Support/Rides/<sessionId>.ndjson (same path used by SessionLogger).
//   - DiagnosticsView can show export stats; ReportIssueView can attach redacted GeoJSON.
//   - SettingsView → Data Export uses this exporter.
//   - Absolutely no 3P SDKs.
//
// Tests to add (summary at bottom):
//   • Round-trip import into other apps (basic schema conformance).
//   • Redaction: first/last segments removed/jittered per policy; path count decreases accordingly.
//   • Multiple sessions merged order and timestamps monotonic after trimming.
//   • Output stable checksum given same inputs.

import Foundation
import CoreLocation
import CryptoKit
import os.log

// MARK: - Redaction Policy

public struct ExportRedactionPolicy: Equatable, Sendable {
    /// Remove the first and last N seconds of the ride (set 0 to keep). Best for “home fuzzing”.
    public var trimHeadSeconds: TimeInterval = 20
    public var trimTailSeconds: TimeInterval = 20

    /// If > 0, additionally trim any points within this radius (meters) of the first/last kept points (post-time-trim).
    public var trimProximityRadiusM: Double = 50

    /// If true, jitter remaining points by up to ±jitterMeters uniformly at random (privacy).
    public var jitterMeters: Double = 0

    /// Clamp maximum horizontal accuracy; points with worse accuracy are dropped.
    public var maxHorizontalAccuracyM: Double = 80

    /// If true, timestamps are kept; otherwise stripped (e.g., for anonymous sharing).
    public var includeTimestamps: Bool = true

    public init() {}
}

// MARK: - Public API

public struct ExportStats: Sendable, Equatable {
    public let inputPoints: Int
    public let exportedPoints: Int
    public let startTimeUTC: Date?
    public let endTimeUTC: Date?
    public let sha256Hex: String
}

public enum ExportFormat { case gpx, geojson }

public protocol GPXExporting {
    func exportSession(_ sessionId: String, format: ExportFormat, policy: ExportRedactionPolicy) throws -> (data: Data, stats: ExportStats)
    func exportSessions(_ sessionIds: [String], mergedAs filenameStem: String, format: ExportFormat, policy: ExportRedactionPolicy) throws -> (fileURL: URL, stats: ExportStats)
}

// MARK: - Service

public final class GPXExporter: GPXExporting {

    // File layout must match SessionLogger
    private let ridesDir: URL
    private let log = Logger(subsystem: "com.skateroute", category: "Export")

    public init(applicationSupportRoot: URL? = nil) {
        let root = applicationSupportRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.ridesDir = root.appendingPathComponent("Rides", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.ridesDir, withIntermediateDirectories: true)
    }

    // MARK: GPX / GeoJSON

    public func exportSession(_ sessionId: String, format: ExportFormat, policy: ExportRedactionPolicy) throws -> (data: Data, stats: ExportStats) {
        let url = ridesDir.appendingPathComponent("\(sessionId).ndjson")
        let samples = try loadAndRedact([url], policy: policy)
        switch format {
        case .gpx:
            let (data, stats) = try makeGPX(samples: samples)
            return (data, stats)
        case .geojson:
            let (data, stats) = try makeGeoJSON(samples: samples)
            return (data, stats)
        }
    }

    /// Merges sessions in timestamp order and writes a temp file with a stable name stem.
    @discardableResult
    public func exportSessions(_ sessionIds: [String],
                               mergedAs filenameStem: String,
                               format: ExportFormat,
                               policy: ExportRedactionPolicy) throws -> (fileURL: URL, stats: ExportStats) {
        let urls = sessionIds.map { ridesDir.appendingPathComponent("\($0).ndjson") }
        let samples = try loadAndRedact(urls, policy: policy)
        let (data, stats): (Data, ExportStats)
        switch format {
        case .gpx:     (data, stats) = try makeGPX(samples: samples)
        case .geojson: (data, stats) = try makeGeoJSON(samples: samples)
        }
        let ext = (format == .gpx) ? "gpx" : "geojson"
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(filenameStem).\(ext)")
        try data.write(to: out, options: .atomic)
        return (out, stats)
    }

    // MARK: Internals — NDJSON → Samples → Redaction

    private struct Sample: Sendable, Equatable {
        let ts: Date?
        let coord: CLLocationCoordinate2D
        let altitude: Double?
        let hAcc: Double?
        let vAcc: Double?
    }

    /// NDJSON tolerant parser: accepts shapes like:
    /// {"ts":1698799601.2,"type":"loc","lat":49.28,"lon":-123.12,"alt":12.3,"h_acc":5.1}
    /// {"time":"2024-10-31T00:00:00Z","lat":49.28,"lng":-123.12}
    private func parseNDJSON(_ url: URL) throws -> [Sample] {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? fh.close() }
        var out: [Sample] = []
        let dec = JSONDecoder()
        for line in LineReader(url: url) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8) else { continue }
            if let s1 = try? dec.decode(LocV1.self, from: data) {
                out.append(s1.sample)
                continue
            }
            if let s2 = try? dec.decode(LocV2.self, from: data) {
                out.append(s2.sample)
                continue
            }
            // Ignore non-location lines
        }
        // Sort by timestamp if present; otherwise preserve file order
        return out.sorted { (a, b) in
            switch (a.ts, b.ts) {
            case let (.some(x), .some(y)): return x < y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return true
            }
        }
    }

    private func loadAndRedact(_ files: [URL], policy: ExportRedactionPolicy) throws -> [Sample] {
        var all: [Sample] = []
        for f in files where FileManager.default.fileExists(atPath: f.path) {
            all.append(contentsOf: try parseNDJSON(f))
        }
        let inputCount = all.count
        guard !all.isEmpty else { return [] }

        // Time trim
        let startTs = all.first?.ts
        let endTs = all.last?.ts
        let trimmedByTime: [Sample] = all.filter { s in
            guard let t = s.ts else { return true } // if unknown, keep unless fails accuracy filter
            if let st = startTs, t.timeIntervalSince(st) < policy.trimHeadSeconds { return false }
            if let et = endTs, et.timeIntervalSince(t) < policy.trimTailSeconds { return false }
            return true
        }

        // Accuracy filter
        let accuracyFiltered = trimmedByTime.filter { s in
            guard let h = s.hAcc else { return true }
            return h <= policy.maxHorizontalAccuracyM
        }
        guard !accuracyFiltered.isEmpty else { return [] }

        // Proximity trim (head/tail clusters)
        let proxTrimmed: [Sample]
        if policy.trimProximityRadiusM > 0, accuracyFiltered.count >= 2 {
            let head = accuracyFiltered.first!
            let tail = accuracyFiltered.last!
            proxTrimmed = accuracyFiltered.filter { s in
                let farFromHead = distance(head.coord, s.coord) >= policy.trimProximityRadiusM || s.ts == head.ts
                let farFromTail = distance(tail.coord, s.coord) >= policy.trimProximityRadiusM || s.ts == tail.ts
                return farFromHead && farFromTail
            }
        } else {
            proxTrimmed = accuracyFiltered
        }

        // Jitter
        let jittered: [Sample]
        if policy.jitterMeters > 0 {
            jittered = proxTrimmed.map { s in
                var c = s.coord
                let (dLat, dLon) = randomJitterMeters(policy.jitterMeters, at: c)
                c.latitude += dLat; c.longitude += dLon
                return Sample(ts: policy.includeTimestamps ? s.ts : nil,
                              coord: c, altitude: s.altitude, hAcc: s.hAcc, vAcc: s.vAcc)
            }
        } else {
            jittered = proxTrimmed.map { s in
                Sample(ts: policy.includeTimestamps ? s.ts : nil,
                       coord: s.coord, altitude: s.altitude, hAcc: s.hAcc, vAcc: s.vAcc)
            }
        }

        // Ensure monotonic timestamps after trimming (drop any out-of-order if present)
        var result: [Sample] = []
        var last: Date? = nil
        for s in jittered {
            if let ts = s.ts, let prev = last, ts < prev { continue }
            result.append(s); last = s.ts ?? last
        }

        // Log stats
        log.debug("Export redaction: \(inputCount, privacy: .public) → \(result.count, privacy: .public) points")
        return result
    }

    // MARK: Renderers

    private func makeGPX(samples: [Sample]) throws -> (Data, ExportStats) {
        guard !samples.isEmpty else { throw ExportError.noSamples }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="SkateRoute" xmlns="http://www.topografix.com/GPX/1/1" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.topografix.com/GPX/1/1/gpx.xsd">
          <metadata>
            <name>SkateRoute Export</name>
            <desc>Redacted export (no PII). Home fuzzing applied.</desc>
          </metadata>
          <trk>
            <name>Session</name>
            <trkseg>
        """

        var exported = 0
        var firstTs: Date? = nil
        var lastTs: Date? = nil

        for s in samples {
            let lat = String(format: "%.6f", s.coord.latitude)
            let lon = String(format: "%.6f", s.coord.longitude)
            xml += "\n      <trkpt lat=\"\(lat)\" lon=\"\(lon)\">"
            if let alt = s.altitude { xml += "\n        <ele>\(String(format: "%.1f", alt))</ele>" }
            if let ts = s.ts {
                xml += "\n        <time>\(iso.string(from: ts))</time>"
                if firstTs == nil { firstTs = ts }
                lastTs = ts
            }
            xml += "\n      </trkpt>"
            exported += 1
        }

        xml += """
        
            </trkseg>
          </trk>
        </gpx>
        """

        let data = Data(xml.utf8)
        let hash = sha256Hex(data)
        // Append checksum as XML comment to end (still valid GPX)
        var final = data
        if let comment = "\n<!-- sha256:\(hash) -->\n".data(using: .utf8) {
            final.append(comment)
        }

        let stats = ExportStats(inputPoints: samples.count,
                                exportedPoints: exported,
                                startTimeUTC: firstTs,
                                endTimeUTC: lastTs,
                                sha256Hex: hash)
        return (final, stats)
    }

    private func makeGeoJSON(samples: [Sample]) throws -> (Data, ExportStats) {
        guard !samples.isEmpty else { throw ExportError.noSamples }

        var coords: [[Double]] = []
        var firstTs: Date? = nil
        var lastTs: Date? = nil

        for s in samples {
            coords.append([round6(s.coord.longitude), round6(s.coord.latitude), s.altitude.map { round1($0) } ?? NSNull() as! Double])
            if let ts = s.ts {
                if firstTs == nil { firstTs = ts }
                lastTs = ts
            }
        }

        // GeoJSON properties: schemaVersion + safe metadata only
        var props: [String: Any] = [
            "name": "SkateRoute Export",
            "schemaVersion": 1,
            "generator": "SkateRoute",
            "redacted": true
        ]
        if let ft = firstTs { props["start_time_utc"] = ISO8601DateFormatter().string(from: ft) }
        if let lt = lastTs { props["end_time_utc"] = ISO8601DateFormatter().string(from: lt) }

        let feature: [String: Any] = [
            "type": "Feature",
            "properties": props,
            "geometry": [
                "type": "LineString",
                "coordinates": coords.map { $0[2].isNaN ? [$0[0], $0[1]] : [$0[0], $0[1], $0[2]] }
            ]
        ]
        let fc: [String: Any] = [
            "type": "FeatureCollection",
            "features": [feature]
        ]

        let data = try JSONSerialization.data(withJSONObject: fc, options: [.prettyPrinted, .withoutEscapingSlashes])
        let hash = sha256Hex(data)
        let stats = ExportStats(inputPoints: samples.count,
                                exportedPoints: coords.count,
                                startTimeUTC: firstTs,
                                endTimeUTC: lastTs,
                                sha256Hex: hash)
        return (data, stats)
    }

    // MARK: Helpers

    private enum ExportError: Error { case noSamples }

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let r = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let h = sin(dLat/2)*sin(dLat/2) + sin(dLon/2)*sin(dLon/2)*cos(lat1)*cos(lat2)
        return 2*r*asin(min(1, sqrt(h)))
    }

    private func randomJitterMeters(_ meters: Double, at coord: CLLocationCoordinate2D) -> (dLat: Double, dLon: Double) {
        let angle = Double.random(in: 0..<(2*Double.pi))
        let d = Double.random(in: 0...meters)
        // Rough meter->degree conversion near given latitude
        let dLat = (d * cos(angle)) / 111_320.0
        let dLon = (d * sin(angle)) / (111_320.0 * cos(coord.latitude * .pi / 180))
        return (dLat, dLon)
    }

    private func round6(_ v: Double) -> Double { (v * 1_000_000).rounded() / 1_000_000 }
    private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    // MARK: NDJSON shapes

    private struct LocV1: Decodable {
        let ts: TS
        let type: String?
        let lat: Double
        let lon: Double
        let alt: Double?
        let hAcc: Double?
        let vAcc: Double?
        enum CodingKeys: String, CodingKey { case ts, type, lat, lon, alt, hAcc = "h_acc", vAcc = "v_acc" }
        var sample: Sample {
            Sample(ts: ts.date(), coord: .init(latitude: lat, longitude: lon), altitude: alt, hAcc: hAcc, vAcc: vAcc)
        }
    }
    private struct LocV2: Decodable {
        let time: String?
        let lat: Double
        let lng: Double
        let altitude: Double?
        let horizontalAccuracy: Double?
        var sample: Sample {
            let d: Date?
            if let t = time {
                d = ISO8601DateFormatter().date(from: t)
            } else { d = nil }
            return Sample(ts: d, coord: .init(latitude: lat, longitude: lng), altitude: altitude, hAcc: horizontalAccuracy, vAcc: nil)
        }
    }
    private enum TS: Decodable {
        case dbl(Double), str(String)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { self = .dbl(d); return }
            let s = try c.decode(String.self); self = .str(s)
        }
        func date() -> Date? {
            switch self {
            case .dbl(let t): return Date(timeIntervalSince1970: t)
            case .str(let s):
                let iso = ISO8601DateFormatter()
                if let d = iso.date(from: s) { return d }
                return Date(timeIntervalSince1970: TimeInterval(Double(s) ?? 0))
            }
        }
    }

    // MARK: Small line reader (memory efficient)

    private struct LineReader: Sequence, IteratorProtocol {
        private let fh: FileHandle?
        private let delim = UInt8(ascii: "\n")
        init(url: URL) { fh = try? FileHandle(forReadingFrom: url) }
        mutating func next() -> String? {
            guard let fh else { return nil }
            var data = Data()
            while true {
                guard let chunk = try? fh.read(upToCount: 1) else { return nil }
                guard let byte = chunk?.first else {
                    // EOF
                    return data.isEmpty ? nil : String(data: data, encoding: .utf8)
                }
                if byte == delim { return String(data: data, encoding: .utf8) }
                data.append(byte)
            }
        }
    }
}

// MARK: - Test plan (unit/E2E summary)
//
// • Round-trip import:
//   - Feed a tiny NDJSON fixture (3 points with ts) → exportSession(.gpx) and (.geojson).
//   - Validate GPX XML contains expected <trkpt> count and ISO8601 <time> values; GeoJSON is valid and LineString length == 3.
//   - Load outputs into a GPX/GeoJSON validator (offline in tests) or parse back to ensure schema.
//
// • Redaction unit tests:
//   - With trimHeadSeconds=30/trimTailSeconds=30 → ensure points within those windows are removed.
//   - With trimProximityRadiusM=100 → ensure any points within 100 m of new head/tail dropped.
//   - With jitterMeters=20 → ensure coordinates differ from originals but remain within ~25 m.
//   - With includeTimestamps=false → ensure <time> elements absent in GPX and properties omit times in GeoJSON.
//
// • Accuracy filter:
//   - Points with h_acc > maxHorizontalAccuracyM are dropped; verify counts.
//
// • Merge ordering:
//   - exportSessions([A,B]) where B starts before A ends; timestamps must remain non-decreasing; verify counts & first/last times.
//
// • Checksums stable:
//   - Hashes identical for repeated runs with the same inputs and zero jitter; differ when jitter>0.
//
// • Error handling:
//   - Missing file yields empty result gracefully (no throw if others exist). All-missing throws noSamples.
//
// Integration wiring:
//   - SettingsView → “Export Ride (GPX/GeoJSON)” buttons call `exportSession(_:format:policy:)` and feed resulting Data/URL into UIActivityViewController.
//   - ReportIssueView attaches redacted GeoJSON by calling `exportSessions(_, mergedAs: "issue-attachment", format: .geojson, policy: strongPolicy)`.
//   - Keep policy defaults privacy-forward: trim 20s head/tail + 50 m proximity; timestamps included by default for fitness platforms.
