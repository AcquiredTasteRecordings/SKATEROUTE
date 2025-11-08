// Services/SessionLogger.swift
import Foundation
import CoreLocation
import os
import Combine

/// `SessionLogger` is responsible for recording ride session data,
/// including location, speed, RMS value, and step index, into CSV log files.
/// It organizes logs into daily timestamped subdirectories and provides
/// utilities for managing and retrieving log files.
public final class SessionLogger: ObservableObject {
    public static let shared = SessionLogger()
    
    private var handle: FileHandle?
    private var currentPath: URL?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SessionLogger", category: "SessionLogger")
    
    /// Publishes the URL of the latest saved log file for SwiftUI components to observe.
    @Published public private(set) var latestLogPath: URL?
    
    private init() {}
    
    /// Returns the directory URL for storing ride logs, organized by date (YYYY-MM-DD).
    /// Creates the directory if it does not exist.
    /// - Throws: An error if the directory cannot be created or accessed.
    private func logsDir() throws -> URL {
        let fm = FileManager.default
        let docs = try fm.url(for: .documentDirectory,
                              in: .userDomainMask,
                              appropriateFor: nil,
                              create: true)
        let rideLogsDir = docs.appendingPathComponent("RideLogs", isDirectory: true)
        
        // Create RideLogs directory if needed
        if !fm.fileExists(atPath: rideLogsDir.path) {
            try fm.createDirectory(at: rideLogsDir, withIntermediateDirectories: true)
        }
        
        // Create a subdirectory for today's date (YYYY-MM-DD)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let todayStr = dateFormatter.string(from: Date())
        let dailyDir = rideLogsDir.appendingPathComponent(todayStr, isDirectory: true)
        if !fm.fileExists(atPath: dailyDir.path) {
            try fm.createDirectory(at: dailyDir, withIntermediateDirectories: true)
        }
        
        return dailyDir
    }
    
    /// Starts a new ride session by creating a new CSV log file with a timestamped filename
    /// inside a daily subdirectory. Writes the CSV header line.
    public func startNewSession() {
        do {
            let dir = try logsDir()
            let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let file = dir.appendingPathComponent("ride-\(ts).csv")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let fh = try FileHandle(forWritingTo: file)
            handle = fh
            currentPath = file
            
            let header = "timestamp,lat,lon,speed_kph,rms,step_index\n"
            try fh.write(contentsOf: Data(header.utf8))
            
            latestLogPath = file
            logger.info("Started new session log at \(file.path, privacy: .public)")
        } catch {
            logger.error("Failed to start new session log: \(error.localizedDescription, privacy: .public)")
            handle = nil
            currentPath = nil
            latestLogPath = nil
        }
    }
    
    /// Appends a new data line to the current session log CSV file.
    /// Safely checks that the file handle is valid and open before writing.
    /// - Parameters:
    ///   - location: The current CLLocation, optional.
    ///   - speedKPH: Speed in kilometers per hour.
    ///   - rms: Root mean square value.
    ///   - stepIndex: Optional step index.
    public func append(location: CLLocation?,
                       speedKPH: Double,
                       rms: Double,
                       stepIndex: Int?) {
        guard let handle = handle else {
            logger.warning("Attempted to append data but file handle is nil")
            return
        }
        
        do {
            #if compiler(>=6.0)
            try handle.seekToEnd()
            #else
            handle.seekToEndOfFile()
            #endif
        } catch {
            logger.warning("Attempted to append data but file handle appears invalid")
            return
        }
        
        let ts = ISO8601DateFormatter().string(from: Date())
        let lat = location?.coordinate.latitude ?? 0
        let lon = location?.coordinate.longitude ?? 0
        let idx = stepIndex.map { String($0) } ?? ""
        let line = "\(ts),\(lat),\(lon),\(speedKPH),\(rms),\(idx)\n"
        do {
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            logger.error("Failed to write data line to session log: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    /// Stops the current session by closing the file handle and resetting state.
    /// Prints the saved log path to the console.
    public func stop() {
        if let handle = handle {
            #if compiler(>=6.0)
            try? handle.close()
            #else
            handle.closeFile()
            #endif
        }
        if let currentPath = currentPath {
            logger.info("📄 Ride log saved to: \(currentPath.path, privacy: .public)")
            latestLogPath = currentPath
        }
        handle = nil
        currentPath = nil
    }
    
    /// Returns the URL of the currently active session log file if any.
    public var activeSessionPath: URL? {
        return currentPath
    }
    
    /// Lists all log files in the RideLogs directory and its subdirectories.
    /// - Returns: An array of URLs pointing to all log files.
    public func listAllLogs() -> [URL] {
        do {
            let fm = FileManager.default
            let rideLogsRoot = try fm.url(for: .documentDirectory,
                                          in: .userDomainMask,
                                          appropriateFor: nil,
                                          create: true)
                .appendingPathComponent("RideLogs", isDirectory: true)
            
            guard fm.fileExists(atPath: rideLogsRoot.path) else {
                return []
            }
            
            let resourceKeys: [URLResourceKey] = [.isDirectoryKey]
            let enumerator = fm.enumerator(at: rideLogsRoot,
                                           includingPropertiesForKeys: resourceKeys,
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants])!
            
            var logFiles: [URL] = []
            for case let fileURL as URL in enumerator {
                let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                if resourceValues.isDirectory == false && fileURL.pathExtension == "csv" {
                    logFiles.append(fileURL)
                }
            }
            return logFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        } catch {
            logger.error("Failed to list all logs: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
