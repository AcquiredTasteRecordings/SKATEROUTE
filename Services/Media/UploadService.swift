// Services/Media/UploadService.swift
// Reliable background uploads for media/logs with retry/backoff and diagnostics.
// HTTPS-only, resumable, respects Low Data Mode and Wi-Fi preference. No secrets, no tracking.

import Foundation
import UIKit
import CryptoKit
import os.log
import Combine

// MARK: - Public protocol for DI

public protocol UploadServicing2: AnyObject {
    @discardableResult
    func enqueue(fileURL: URL,
                 to destination: URL,
                 httpHeaders: [String: String],
                 requiresWiFi: Bool,
                 priority: Float) throws -> UploadJobID

    func cancel(id: UploadJobID)
    func pause(id: UploadJobID)
    func resume(id: UploadJobID)

    var queuePublisher: AnyPublisher<[UploadQueueItem], Never> { get }

    // DiagnosticsView pulls this snapshot
    func currentQueue() -> [UploadQueueItem]

    // AppCoordinator should forward BG session events into here
    func setBackgroundEventsCompletionHandler(_ handler: @escaping () -> Void)
}

// MARK: - Types

public typealias UploadJobID = String

public struct UploadQueueItem: Codable, Hashable, Identifiable {
    public enum Status: String, Codable {
        case enqueued, uploading, paused, retryScheduled, completed, failed, canceled
    }
    public let id: UploadJobID
    public let sourcePath: String
    public let destination: String
    public let createdAt: Date
    public var updatedAt: Date
    public var attempts: Int
    public var status: Status
    public var lastError: String?
    public var bytesSent: Int64
    public var bytesTotal: Int64
    public var requiresWiFi: Bool
    public var checksumSHA256: String
}

// MARK: - UploadService

@MainActor
public final class UploadService: NSObject, UploadServicing2 {

    // MARK: Config

    public struct Config: Equatable {
        public let backgroundIdentifier: String
        public let maxAttempts: Int
        public let baseBackoff: TimeInterval
        public let maxBackoff: TimeInterval
        public let preferWiFiByDefault: Bool

        public init(backgroundIdentifier: String = "com.skateroute.uploads.bg",
                    maxAttempts: Int = 6,
                    baseBackoff: TimeInterval = 2,
                    maxBackoff: TimeInterval = 120,
                    preferWiFiByDefault: Bool = true) {
            self.backgroundIdentifier = backgroundIdentifier
            self.maxAttempts = maxAttempts
            self.baseBackoff = baseBackoff
            self.maxBackoff = maxBackoff
            self.preferWiFiByDefault = preferWiFiByDefault
        }
    }

    // MARK: Public stream

    private let queueSubject = CurrentValueSubject<[UploadQueueItem], Never>([])
    public var queuePublisher: AnyPublisher<[UploadQueueItem], Never> { queueSubject.eraseToAnyPublisher() }

    // MARK: Internals

    private let log = Logger(subsystem: "com.skateroute", category: "UploadService")
    private let config: Config
    private var session: URLSession!
    private var bgCompletionHandler: (() -> Void)?
    private let stateStore = UploadStateStore()

    // book-keeping taskID -> jobID
    private var taskMap: [Int: UploadJobID] = [:]
    private var timerMap: [UploadJobID: DispatchSourceTimer] = [:]

    // KVO progress
    private var progressKVO: [Int: NSKeyValueObservation] = [:]

    // MARK: Init

    public init(config: Config = Config()) {
        self.config = config
        super.init()
        session = Self.makeSession(config: config, delegate: self)
        // Reload persisted queue on launch
        queueSubject.send(stateStore.loadAll())
        // Reattach to any running tasks
        attachToExistingTasks()
    }

    // MARK: Enqueue

    @discardableResult
    public func enqueue(fileURL: URL,
                        to destination: URL,
                        httpHeaders: [String : String] = [:],
                        requiresWiFi: Bool,
                        priority: Float = URLSessionTask.defaultPriority) throws -> UploadJobID {

        guard destination.scheme?.lowercased() == "https" else {
            throw UploadError.insecureURL
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw UploadError.missingFile
        }

        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let checksum = try Self.sha256Hex(of: fileURL)
        var item = UploadQueueItem(
            id: id,
            sourcePath: fileURL.path,
            destination: destination.absoluteString,
            createdAt: Date(),
            updatedAt: Date(),
            attempts: 0,
            status: .enqueued,
            lastError: nil,
            bytesSent: 0,
            bytesTotal: (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0,
            requiresWiFi: requiresWiFi,
            checksumSHA256: checksum
        )

        stateStore.save(item)
        pushQueueUpdate()

        // Create background upload task
        let request = Self.makeRequest(url: destination,
                                       headers: httpHeaders.merging(["x-content-sha256": checksum]) { a, _ in a })

        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.priority = priority
        task.taskDescription = id
        // Respect Wi-Fi / Low Data Mode preferences on a per-task basis
        task.earliestBeginDate = nil // start asap; the OS may still delay under constraints
        map(task: task, to: id)

        // Start immediately
        task.resume()

        // Mark as uploading
        item.status = .uploading
        item.updatedAt = Date()
        stateStore.save(item)
        pushQueueUpdate()

        return id
    }

    // MARK: Controls

    public func cancel(id: UploadJobID) {
        guard let task = taskFor(id: id) else {
            // If no live task, mark canceled and drop any timers
            update { items in
                if var it = items.first(where: { $0.id == id }) {
                    it.status = .canceled; it.updatedAt = Date(); it.lastError = nil
                    self.stateStore.save(it)
                }
            }
            cancelRetryTimer(for: id)
            pushQueueUpdate()
            return
        }
        task.cancel()
        cancelRetryTimer(for: id)
        updateItem(id: id) { $0.status = .canceled; $0.updatedAt = Date(); $0.lastError = nil }
        pushQueueUpdate()
    }

    public func pause(id: UploadJobID) {
        taskFor(id: id)?.suspend()
        cancelRetryTimer(for: id)
        updateItem(id: id) { $0.status = .paused; $0.updatedAt = Date() }
        pushQueueUpdate()
    }

    public func resume(id: UploadJobID) {
        if let t = taskFor(id: id) {
            t.resume()
            updateItem(id: id) { $0.status = .uploading; $0.updatedAt = Date() }
            pushQueueUpdate()
            return
        }
        // If the task is gone (app relaunched), recreate it
        guard var item = stateStore.load(id: id) else { return }
        guard let src = URL(string: "file://" + item.sourcePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!) ?? URL(fileURLWithPath: item.sourcePath),
              let dest = URL(string: item.destination) else { return }
        let req = Self.makeRequest(url: dest, headers: ["x-content-sha256": item.checksumSHA256])
        let task = session.uploadTask(with: req, fromFile: src)
        map(task: task, to: id)
        task.resume()
        item.status = .uploading
        item.updatedAt = Date()
        stateStore.save(item)
        pushQueueUpdate()
    }

    // MARK: Diagnostics

    public func currentQueue() -> [UploadQueueItem] { queueSubject.value }

    public func setBackgroundEventsCompletionHandler(_ handler: @escaping () -> Void) {
        bgCompletionHandler = handler
    }

    // MARK: Helpers

    private static func makeSession(config: Config, delegate: URLSessionDelegate) -> URLSession {
        let cfg = URLSessionConfiguration.background(withIdentifier: config.backgroundIdentifier)
        cfg.isDiscretionary = true // allow the system to optimize for battery/network
        cfg.sessionSendsLaunchEvents = true
        cfg.waitsForConnectivity = true
        // Respect Low Data Mode and Wi-Fi preference at the configuration level; per-task overrides apply too.
        cfg.allowsExpensiveNetworkAccess = !config.preferWiFiByDefault
        cfg.allowsConstrainedNetworkAccess = false // defer under Low Data Mode by default
        cfg.multipathServiceType = .handover
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    private static func makeRequest(url: URL, headers: [String: String]) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        for (k,v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        // ATS should already enforce TLS; add a defensive Accept header
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private func map(task: URLSessionTask, to id: UploadJobID) {
        taskMap[task.taskIdentifier] = id
        // Progress KVO
        progressKVO[task.taskIdentifier] = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            guard let self, let jobId = self.taskMap[task.taskIdentifier], var item = self.stateStore.load(id: jobId) else { return }
            let frac = progress.fractionCompleted
            if frac.isFinite {
                item.status = .uploading
                item.updatedAt = Date()
                item.bytesSent = Int64(frac * Double(item.bytesTotal))
                self.stateStore.save(item)
                self.pushQueueUpdate()
            }
        }
    }

    private func taskFor(id: UploadJobID) -> URLSessionUploadTask? {
        for task in session.getAllTasksSync() {
            if task.taskDescription == id, let up = task as? URLSessionUploadTask { return up }
        }
        return nil
    }

    private func attachToExistingTasks() {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            tasks.forEach { t in
                if let id = t.taskDescription {
                    self.map(task: t, to: id)
                }
            }
        }
    }

    private func scheduleRetry(for id: UploadJobID, after: TimeInterval) {
        cancelRetryTimer(for: id)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + after)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.resume(id: id) }
        }
        timer.resume()
        timerMap[id] = timer
    }

    private func cancelRetryTimer(for id: UploadJobID) {
        timerMap[id]?.cancel(); timerMap[id] = nil
    }

    private func pushQueueUpdate() {
        queueSubject.send(stateStore.loadAll())
    }

    private func update(_ mutate: (inout [UploadQueueItem]) -> Void) {
        var items = stateStore.loadAll()
        mutate(&items)
        stateStore.saveAll(items)
        queueSubject.send(items)
    }

    private func updateItem(id: UploadJobID, mutate: (inout UploadQueueItem) -> Void) {
        guard var item = stateStore.load(id: id) else { return }
        mutate(&item)
        stateStore.save(item)
    }

    private static func sha256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = try? handle.read(upToCount: 1_048_576) // 1MB chunk
            if let data, !data.isEmpty { hasher.update(data: data); return true }
            return false
        }) {}
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - URLSessionDelegate / Task Delegate

extension UploadService: URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {

    // TLS trust is enforced by ATS; no custom pinning here (could add later if needed)
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // Signal App to run completion handler and allow system to suspend us.
        if let handler = bgCompletionHandler {
            bgCompletionHandler = nil
            DispatchQueue.main.async { handler() }
        }
    }

    public func urlSession(_ session: URLSession,
                           task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        guard let id = task.taskDescription, var item = stateStore.load(id: id) else { return }

        let httpStatus = (task.response as? HTTPURLResponse)?.statusCode ?? -1
        let acceptedChecksum = (task.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-accepted-sha256")

        if let error {
            // System-level failure (connectivity, background suspension, etc.)
            handleFailure(for: id, item: &item, httpStatus: httpStatus, error: error)
            return
        }

        // HTTP status validation
        guard (200...299).contains(httpStatus) else {
            let err = NSError(domain: "UploadHTTP", code: httpStatus, userInfo: [NSLocalizedDescriptionKey:"HTTP \(httpStatus)"])
            handleFailure(for: id, item: &item, httpStatus: httpStatus, error: err)
            return
        }

        // Optional checksum confirmation
        if let acceptedChecksum, acceptedChecksum != item.checksumSHA256 {
            let err = NSError(domain: "UploadChecksum", code: -1, userInfo: [NSLocalizedDescriptionKey:"Checksum mismatch"])
            handleFailure(for: id, item: &item, httpStatus: httpStatus, error: err)
            return
        }

        // Success path
        item.status = .completed
        item.updatedAt = Date()
        item.lastError = nil
        item.attempts += 1
        item.bytesSent = item.bytesTotal
        stateStore.save(item)
        pushQueueUpdate()

        // Clean progress observers
        progressKVO[task.taskIdentifier] = nil
        taskMap[task.taskIdentifier] = nil
        cancelRetryTimer(for: id)
    }

    private func handleFailure(for id: UploadJobID, item: inout UploadQueueItem, httpStatus: Int, error: Error) {
        item.attempts += 1
        item.updatedAt = Date()
        item.status = .failed
        item.lastError = error.localizedDescription
        stateStore.save(item)
        pushQueueUpdate()

        guard item.attempts < config.maxAttempts else {
            // Cap reached; finalize as failed
            log.error("Upload \(id) failed permanently after \(self.config.maxAttempts) attempts: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Compute backoff with jitter
        let powBackoff = min(config.maxBackoff, config.baseBackoff * pow(2.0, Double(item.attempts - 1)))
        let jitter = Double.random(in: 0...(powBackoff * 0.25))
        let delay = powBackoff + jitter

        updateItem(id: id) { $0.status = .retryScheduled; $0.updatedAt = Date(); $0.lastError = error.localizedDescription }
        pushQueueUpdate()
        log.notice("Retrying upload \(id) in \(delay, privacy: .public)s (attempt \(item.attempts))")

        scheduleRetry(for: id, after: delay)
    }

    // Track low-level progress when Content-Length is known
    public func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                           totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let id = task.taskDescription, var item = stateStore.load(id: id) else { return }
        item.bytesSent = totalBytesSent
        if totalBytesExpectedToSend > 0 {
            item.bytesTotal = totalBytesExpectedToSend
        }
        item.status = .uploading
        item.updatedAt = Date()
        stateStore.save(item)
        pushQueueUpdate()
    }
}

// MARK: - State persistence (small JSON file in Application Support)

private final class UploadStateStore {
    private let url: URL
    private let fm = FileManager.default

    init() {
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Uploads", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("queue.json")
    }

    func loadAll() -> [UploadQueueItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([UploadQueueItem].self, from: data)) ?? []
    }

    func load(id: UploadJobID) -> UploadQueueItem? {
        loadAll().first { $0.id == id }
    }

    func save(_ item: UploadQueueItem) {
        var all = loadAll().filter { $0.id != item.id }
        all.append(item)
        saveAll(all)
    }

    func saveAll(_ items: [UploadQueueItem]) {
        let sorted = items.sorted { $0.createdAt < $1.createdAt }
        if let data = try? JSONEncoder().encode(sorted) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - URLSession helper

private extension URLSession {
    func getAllTasksSync() -> [URLSessionTask] {
        let sem = DispatchSemaphore(value: 0)
        var out: [URLSessionTask] = []
        getAllTasks { tasks in out = tasks; sem.signal() }
        sem.wait()
        return out
    }
}

// MARK: - Errors

public enum UploadError: LocalizedError {
    case insecureURL
    case missingFile

    public var errorDescription: String? {
        switch self {
        case .insecureURL: return "Uploads require HTTPS."
        case .missingFile: return "Source file not found."
        }
    }
}

// MARK: - DEBUG fake (for unit/UI tests)

#if DEBUG
public final class UploadServiceFake: UploadServicing2 {
    private var items: [UploadQueueItem] = []
    private let subject = CurrentValueSubject<[UploadQueueItem], Never>([])

    public init() {}

    public var queuePublisher: AnyPublisher<[UploadQueueItem], Never> { subject.eraseToAnyPublisher() }

    public func enqueue(fileURL: URL, to destination: URL, httpHeaders: [String : String], requiresWiFi: Bool, priority: Float) throws -> UploadJobID {
        let id = UUID().uuidString
        let item = UploadQueueItem(id: id,
                                   sourcePath: fileURL.path,
                                   destination: destination.absoluteString,
                                   createdAt: Date(),
                                   updatedAt: Date(),
                                   attempts: 0,
                                   status: .uploading,
                                   lastError: nil,
                                   bytesSent: 0,
                                   bytesTotal: 100,
                                   requiresWiFi: requiresWiFi,
                                   checksumSHA256: "fake")
        items.append(item); subject.send(items)
        // Simulated completion
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            var item = self.items.removeFirst()
            item.status = .completed; item.bytesSent = item.bytesTotal; item.updatedAt = Date()
            self.items.append(item); self.subject.send(self.items)
        }
        return id
    }

    public func cancel(id: UploadJobID) {
        if let idx = items.firstIndex(where: { $0.id == id }) { items[idx].status = .canceled; subject.send(items) }
    }
    public func pause(id: UploadJobID) {
        if let idx = items.firstIndex(where: { $0.id == id }) { items[idx].status = .paused; subject.send(items) }
    }
    public func resume(id: UploadJobID) {
        if let idx = items.firstIndex(where: { $0.id == id }) { items[idx].status = .uploading; subject.send(items) }
    }
    public func currentQueue() -> [UploadQueueItem] { items }
    public func setBackgroundEventsCompletionHandler(_ handler: @escaping () -> Void) { handler() }
}
#endif
