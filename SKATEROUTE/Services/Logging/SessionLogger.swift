// Services/SessionLogger.swift
// Lightweight NDJSON session logger for ride telemetry.
// - Thread-safe writes via a serial queue
// - Lazy file open; safe close
// - Privacy: quantizes coords, optional redaction of speed/RMS
// - Rotation: keeps recent logs, prunes older ones

import Foundation
import CoreLocation
import os
import UIKit

public final class SessionLogger {

    // MARK: - Public singleton
    public static let shared = SessionLogger()

    // MARK: - Types

    public struct Config {
        /// Where to write files. Defaults to Caches/Rides
        public var directoryURL: URL
        /// Max log files to keep (oldest pruned on start). 0 = no pruning.
        public var keepMostRecent: Int
        /// Coordinate precision (decimal places) for privacy.
        public var coordPrecision: Int
        /// If true, speeds are rounded to nearest 0.5 km/h.
        public var quantizeSpeed: Bool
        /// If true, roughness RMS is rounded to 0.005 g.
        public var quantizeRMS: Bool

        public init(
            directoryURL: URL = SessionLogger.defaultDirectory(),
            keepMostRecent: Int = 15,
            coordPrecision: Int = 5,
            quantizeSpeed: Bool = true,
            quantizeRMS: Bool = true
        ) {
            self.directoryURL = directoryURL
            self.keepMostRecent = keepMostRecent
            self.coordPrecision = coordPrecision
            self.quantizeSpeed = quantizeSpeed
            self.quantizeRMS = quantizeRMS
        }
    }

    /// Envelope for NDJSON record lines.
    private struct Record: Encodable {
        let ts: String                 // ISO8601
        let event: String              // "telemetry" | "session.start" | "session.stop"
        let lat: Double?               // quantized deg
        let lon: Double?               // quantized deg
        let speedKph: Double?          // quantized
        let rms: Double?               // quantized
        let stepIndex: Int?
        let extra: [String: String]?   // reserved for future small fields
    }

    // MARK: - State

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SKATEROUTE", category: "SessionLogger")
    private let queue = DispatchQueue(label: "SessionLogger.queue", qos: .utility)
    private var fh: FileHandle?
    private var currentURL: URL?
    private var sessionId: String?
    private var config: Config = .init()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    // Background task for long writes (best effort)
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    // MARK: - Lifecycle

    private init() {
        ensureDirectory(config.directoryURL)
    }

    // MARK: - Public API (matches DI)

    /// Starts a new session file and writes a `session.start` line.
    public func startNewSession() {
        queue.async {
            self.rotateIfNeeded()
            self.sessionId = Self.makeSessionId()
            let filename = "\(self.sessionId!).ndjson"
            self.currentURL = self.config.directoryURL.appendingPathComponent(filename)
            self.openIfNeeded()

            self.writeLine(event: "session.start",
                           coord: nil,
                           speedKph: nil,
                           rms: nil,
                           stepIndex: nil,
                           extra: ["appVersion": Self.appVersionString()])
        }
    }

    /// Appends a telemetry record: location (optional), speed (km/h), roughness (g), step index.
    public func append(location: CLLocation?, speedKPH: Double, rms: Double, stepIndex: Int?) {
        queue.async {
            guard self.currentURL != nil else { return } // ignore until started
            let coord = location?.coordinate
            let qCoord = coord.map { (self.quantize($0.latitude, places: self.config.coordPrecision),
                                      self.quantize($0.longitude, places: self.config.coordPrecision)) }

            let qSpeed = speedKPH.isFinite ? (self.config.quantizeSpeed ? Self.round(speedKPH, to: 0.5) : speedKPH) : nil
            let qRMS = rms.isFinite ? (self.config.quantizeRMS ? Self.round(rms, to: 0.005) : rms) : nil

            self.writeLine(
                event: "telemetry",
                coord: qCoord,
                speedKph: qSpeed,
                rms: qRMS,
                stepIndex: stepIndex,
                extra: nil
            )
        }
    }

    /// Stops the current session and writes a `session.stop` line.
    public func stop() {
        queue.async {
            guard self.currentURL != nil else { return }
            self.writeLine(event: "session.stop", coord: nil, speedKph: nil, rms: nil, stepIndex: nil, extra: nil)
            self.close()
            self.sessionId = nil
            self.currentURL = nil
        }
    }

    // MARK: - Configuration

    /// Override defaults (directory, retention, quantization).
    /// Can be called between sessions; does not affect an open file.
    public func apply(_ config: Config) {
        queue.async {
            self.config = config
            self.ensureDirectory(config.directoryURL)
        }
    }

    /// Returns the file URL for the current session if open.
    public func currentFileURL() -> URL? {
        queue.sync { currentURL }
    }

    // MARK: - Internals

    private func writeLine(event: String,
                           coord: (Double, Double)?,
                           speedKph: Double?,
                           rms: Double?,
                           stepIndex: Int?,
                           extra: [String: String]?) {
        openIfNeeded()

        let ts = ISO8601DateFormatter().string(from: Date())
        let rec = Record(
            ts: ts,
            event: event,
            lat: coord?.0,
            lon: coord?.1,
            speedKph: speedKph,
            rms: rms,
            stepIndex: stepIndex,
            extra: extra
        )

        guard let data = try? JSONEncoder().encode(rec) else { return }
        guard let fh = fh else { return }

        beginBackgroundTaskIfNeeded()
        defer { endBackgroundTaskIfNeeded() }

        do {
            try fh.write(contentsOf: data)
            try fh.write(contentsOf: Data([0x0A])) // newline
        } catch {
            log.error("Write failed: \(error.localizedDescription)")
        }
    }

    private func openIfNeeded() {
        guard fh == nil, let url = currentURL else { return }
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            fh = try FileHandle(forWritingTo: url)
            try fh?.seekToEnd()
        } catch {
            log.error("Open failed: \(error.localizedDescription)")
            fh = nil
        }
    }

    private func close() {
        do {
            try fh?.close()
        } catch {
            // ignore
        }
        fh = nil
    }

    private func ensureDirectory(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            log.error("Directory create failed: \(error.localizedDescription)")
        }
    }

    private func rotateIfNeeded() {
        guard config.keepMostRecent > 0 else { return }
        let dir = config.directoryURL
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else { return }
        let logs = items.filter { $0.pathExtension.lowercased() == "ndjson" }
            .compactMap { url -> (URL, Date) in
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                return (url, date)
            }
            .sorted(by: { $0.1 > $1.1 })

        if logs.count > config.keepMostRecent {
            for (url, _) in logs.suffix(from: config.keepMostRecent) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func beginBackgroundTaskIfNeeded() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "SessionLoggerWrite") { [weak self] in
            self?.endBackgroundTaskIfNeeded()
        }
    }

    private func endBackgroundTaskIfNeeded() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    // MARK: - Helpers

    private static func makeSessionId() -> String {
        // e.g., 2025-11-08T03-45-12Z_7F2C4A
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime]
        let now = df.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let suffix = UUID().uuidString.prefix(6)
        return "\(now)_\(suffix)"
    }

    private static func appVersionString() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(v) (\(b))"
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Rides", isDirectory: true)
    }

    private func quantize(_ value: Double, places: Int) -> Double {
        guard places >= 0 else { return value }
        let p = pow(10.0, Double(places))
        return (value * p).rounded() / p
    }

    private static func round(_ value: Double, to step: Double) -> Double {
        guard step > 0 else { return value }
        return (value / step).rounded() * step
    }
}


