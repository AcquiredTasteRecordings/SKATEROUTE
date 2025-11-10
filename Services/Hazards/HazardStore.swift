// Services/Hazards/HazardStore.swift
// Durable hazard graph (potholes, gravel, rails) with local cache + remote sync.
// Proximity/type de-dupe + merge, TTL expiry, resilient offline queue, Combine surfaces.

import Foundation
import Combine
import SwiftData
import MapKit
import os.log

// MARK: - Hazard Model

public enum HazardKind: String, Codable, CaseIterable {
    case pothole, gravel, rail, crack, debris, wet, other
}

public enum HazardStatus: String, Codable, CaseIterable { case active, resolved, expired }

@Model
public final class HazardReport {
    @Attribute(.unique) public var id: String
    public var kind: HazardKind
    public var lat: Double
    public var lon: Double
    public var severity: Int            // 1..5 (light → gnarly)
    public var confirmations: Int       // merged reports bump this
    public var createdAt: Date
    public var updatedAt: Date
    public var expiresAt: Date?         // TTL-driven; nil = until resolved
    public var status: HazardStatus     // active/resolved/expired
    public var lastSyncedAt: Date?
    public var version: Int

    public init(id: String,
                kind: HazardKind,
                lat: Double,
                lon: Double,
                severity: Int,
                confirmations: Int = 1,
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                expiresAt: Date? = nil,
                status: HazardStatus = .active,
                lastSyncedAt: Date? = nil,
                version: Int = 1) {
        self.id = id
        self.kind = kind
        self.lat = lat
        self.lon = lon
        self.severity = max(1, min(severity, 5))
        self.confirmations = confirmations
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.status = status
        self.lastSyncedAt = lastSyncedAt
        self.version = version
    }

    public var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

// MARK: - Cloud DTO + Remote seams

public struct CloudHazard: Codable, Equatable, Sendable {
    public let id: String
    public let kind: HazardKind
    public let coordinate: CLLocationCoordinate2D
    public let severity: Int
    public let confirmations: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let expiresAt: Date?
    public let status: HazardStatus
    public let serverTimestamp: Date
}

public protocol HazardRemoteAPI {
    /// Fetch hazards newer than `since` in descending time order. Opaque since-token.
    func fetchSince(_ since: String?, pageSize: Int) async throws -> (items: [CloudHazard], nextSince: String?)
    /// Upsert a local hazard (create or merge). Returns authoritative cloud copy.
    func upsert(_ hazard: CloudHazard) async throws -> CloudHazard
    /// Mark hazard resolved by id.
    func resolve(id: String) async throws -> CloudHazard
}

// MARK: - Rules: de-dupe & TTL (coarse; fine rules can live in HazardRules.swift)

public struct HazardRules {
    public var mergeRadiusMeters: Double = 18.0  // same-kind hazards within this radius merge
    public var ttlByKindDays: [HazardKind: Double] = [
        .wet: 1, .debris: 2, .gravel: 7, .pothole: 60, .rail: 365, .crack: 120, .other: 14
    ]
    public init() {}
    public func ttl(for kind: HazardKind) -> TimeInterval? {
        ttlByKindDays[kind].map { $0 * 86400 }
    }
}

// MARK: - Store

@MainActor
public final class HazardStore: ObservableObject {
    public enum State: Equatable { case idle, loading, ready, error(String) }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var hazardsInView: [HazardReport] = []

    public var hazardsPublisher: AnyPublisher<[HazardReport], Never> { $hazardsInView.eraseToAnyPublisher() }

    private let modelContext: ModelContext
    private let remote: HazardRemoteAPI
    private let rules: HazardRules
    private let log = Logger(subsystem: "com.skateroute", category: "HazardStore")

    // Sync state
    private var sinceToken: String?
    private var isSyncing = false

    // Spatial index for fast region queries + proximity merges
    private let index = HazardSpatialIndex()

    // Outbox for offline writes (persisted)
    private let outbox = HazardOutbox()

    public init(modelContext: ModelContext, remote: HazardRemoteAPI, rules: HazardRules = .init()) {
        self.modelContext = modelContext
        self.remote = remote
        this.rules = rules
        rebuildIndex()
    }

    // MARK: Bootstrap

    public func load() async {
        state = .loading
        expireIfNeeded()
        rebuildIndex()
        state = .ready
        await syncIfNeeded()
    }

    // MARK: Create / Merge

    /// Creates a new hazard or merges with a nearby same-kind one (proximity/type de-dupe).
    @discardableResult
    public func report(kind: HazardKind,
                       coordinate: CLLocationCoordinate2D,
                       severity: Int) async throws -> HazardReport {
        // If a same-kind hazard exists within merge radius, merge locally
        if let existingId = index.findNearest(kind: kind, near: coordinate, withinMeters: rules.mergeRadiusMeters),
           let existing = try fetchLocal(id: existingId) {
            existing.confirmations += 1
            existing.severity = max(existing.severity, severity)
            existing.updatedAt = Date()
            // Extend TTL if applicable
            if let ttl = rules.ttl(for: kind) {
                existing.expiresAt = Date().addingTimeInterval(ttl)
            }
            try modelContext.save()
            // Queue upsert
            outbox.enqueue(.upsert(existing.toCloud()))
            Task { await syncOutbox() }
            rebuildIndexIfMoved(existing) // confirmations shouldn’t move, but keep it safe
            return existing
        }

        // Else create a fresh report
        let now = Date()
        let id = UUID().uuidString
        let expires = rules.ttl(for: kind).map { now.addingTimeInterval($0) }
        let local = HazardReport(id: id,
                                 kind: kind,
                                 lat: coordinate.latitude,
                                 lon: coordinate.longitude,
                                 severity: severity,
                                 confirmations: 1,
                                 createdAt: now,
                                 updatedAt: now,
                                 expiresAt: expires,
                                 status: .active,
                                 lastSyncedAt: nil,
                                 version: 1)
        modelContext.insert(local)
        try modelContext.save()

        // Write-through to outbox and kick sync
        outbox.enqueue(.upsert(local.toCloud()))
        Task { await syncOutbox() }
        index.add(local)
        return local
    }

    // MARK: Resolve / Expire

    public func resolve(id: String) async {
        guard let local = try? fetchLocal(id: id) else { return }
        local.status = .resolved
        local.updatedAt = Date()
        try? modelContext.save()
        outbox.enqueue(.resolve(id))
        Task { await syncOutbox() }
        rebuildIndex()
    }

    /// Periodically mark expired reports and purge them from index; keep on disk for audit.
    public func expireIfNeeded(now: Date = Date()) {
        let all = (try? modelContext.fetch(FetchDescriptor<HazardReport>())) ?? []
        var changed = false
        for h in all where h.status == .active {
            if let exp = h.expiresAt, now >= exp {
                h.status = .expired
                h.updatedAt = now
                changed = true
            }
        }
        if changed { try? modelContext.save(); rebuildIndex() }
    }

    // MARK: Query for UI (Overlay/List)

    /// Get currently active hazards intersecting the map region.
    @discardableResult
    public func query(in region: MKCoordinateRegion) -> [HazardReport] {
        let ids = index.query(region: region)
        let active = ids.compactMap { try? fetchLocal(id: $0) }.filter { $0?.status == .active }
        hazardsInView = active
        return active
    }

    // MARK: Sync

    public func syncIfNeeded(pageSize: Int = 200) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        // Drain outbox first (best effort)
        await syncOutbox()

        // Pull newer items from server
        do {
            var next = sinceToken
            var mutated = false
            repeat {
                let (page, token) = try await remote.fetchSince(next, pageSize: pageSize)
                next = token
                if !page.isEmpty {
                    for cloud in page {
                        applyRemote(cloud)
                        mutated = true
                    }
                    try modelContext.save()
                }
            } while next != nil
            if mutated { rebuildIndex() }
            sinceToken = next ?? sinceToken
        } catch {
            log.error("Hazard sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyRemote(_ cloud: CloudHazard) {
        let local = try? fetchLocal(id: cloud.id)
        let skew: TimeInterval = 2.0
        if let h = local {
            // Keep local if it's clearly newer (recover later)
            if h.updatedAt > cloud.serverTimestamp.addingTimeInterval(skew) { return }
            h.kind = cloud.kind
            h.lat = cloud.coordinate.latitude
            h.lon = cloud.coordinate.longitude
            h.severity = cloud.severity
            h.confirmations = max(h.confirmations, cloud.confirmations)
            h.createdAt = cloud.createdAt
            h.updatedAt = cloud.updatedAt
            h.expiresAt = cloud.expiresAt
            h.status = cloud.status
            h.lastSyncedAt = Date()
            h.version = max(h.version, h.version + 1)
        } else {
            let h = HazardReport(id: cloud.id,
                                 kind: cloud.kind,
                                 lat: cloud.coordinate.latitude,
                                 lon: cloud.coordinate.longitude,
                                 severity: cloud.severity,
                                 confirmations: cloud.confirmations,
                                 createdAt: cloud.createdAt,
                                 updatedAt: cloud.updatedAt,
                                 expiresAt: cloud.expiresAt,
                                 status: cloud.status,
                                 lastSyncedAt: Date(),
                                 version: 1)
            modelContext.insert(h)
        }
    }

    // MARK: Outbox sync (error recovery with capped backoff)

    private func syncOutbox() async {
        guard outbox.hasItems else { return }
        // Try to process in small batches
        var attempts = 0
        while let op = outbox.peek() {
            do {
                switch op {
                case .upsert(let c):
                    let ack = try await remote.upsert(c)
                    applyRemote(ack)
                    try modelContext.save()
                case .resolve(let id):
                    let ack = try await remote.resolve(id: id)
                    applyRemote(ack)
                    try modelContext.save()
                }
                outbox.pop()
                attempts = 0 // reset backoff on progress
            } catch {
                attempts += 1
                let delay = min(60.0, pow(2.0, Double(min(attempts, 5)))) // 1,2,4,8,16,32,60
                log.notice("Hazard outbox retry in \(delay, privacy: .public)s: \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        rebuildIndex()
    }

    // MARK: Internals

    private func fetchLocal(id: String) throws -> HazardReport? {
        try modelContext.fetch(FetchDescriptor<HazardReport>(predicate: #Predicate { $0.id == id })).first
    }

    private func rebuildIndex() {
        let all = (try? modelContext.fetch(FetchDescriptor<HazardReport>())) ?? []
        index.rebuild(with: all.filter { $0.status == .active }.map { ($0.id, $0.coordinate, $0.kind) })
    }

    private func rebuildIndexIfMoved(_ h: HazardReport) {
        index.update(id: h.id, to: h.coordinate, kind: h.kind)
    }
}

// MARK: - Spatial Index (grid + proximity)

fileprivate final class HazardSpatialIndex {
    struct Point { let id: String; var coord: CLLocationCoordinate2D; var kind: HazardKind }
    private var byId: [String: Point] = [:]
    private var points: [Point] = []

    func rebuild(with entries: [(String, CLLocationCoordinate2D, HazardKind)]) {
        byId.removeAll(keepingCapacity: true)
        points = entries.map { Point(id: $0.0, coord: $0.1, kind: $0.2) }
        for p in points { byId[p.id] = p }
    }

    func update(id: String, to coord: CLLocationCoordinate2D, kind: HazardKind) {
        if var p = byId[id] {
            p.coord = coord; p.kind = kind; byId[id] = p
            if let idx = points.firstIndex(where: { $0.id == id }) { points[idx] = p }
        }
    }

    func add(_ h: HazardReport) {
        let p = Point(id: h.id, coord: h.coordinate, kind: h.kind)
        byId[h.id] = p; points.append(p)
    }

    func query(region: MKCoordinateRegion) -> [String] {
        guard !points.isEmpty else { return [] }
        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLon = normalizeLon(region.center.longitude - region.span.longitudeDelta / 2)
        let maxLon = normalizeLon(region.center.longitude + region.span.longitudeDelta / 2)
        let cross = maxLon < minLon
        var ids: [String] = []
        for p in points where p.coord.latitude >= minLat && p.coord.latitude <= maxLat {
            let L = normalizeLon(p.coord.longitude)
            if (!cross && L >= minLon && L <= maxLon) || (cross && (L <= maxLon || L >= minLon)) {
                ids.append(p.id)
            }
        }
        return ids
    }

    /// Returns nearest hazard id of same kind within threshold (meters), else nil.
    func findNearest(kind: HazardKind, near coord: CLLocationCoordinate2D, withinMeters: Double) -> String? {
        var bestId: String?
        var bestD: Double = withinMeters
        for p in points where p.kind == kind {
            let d = haversine(coord, p.coord)
            if d <= bestD { bestD = d; bestId = p.id }
        }
        return bestId
    }

    private func haversine(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let r = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let h = sin(dLat/2)*sin(dLat/2) + sin(dLon/2)*sin(dLon/2)*cos(lat1)*cos(lat2)
        return 2*r*asin(min(1, sqrt(h)))
    }

    private func normalizeLon(_ lon: Double) -> Double {
        var L = lon
        while L < -180 { L += 360 }
        while L >  180 { L -= 360 }
        return L
    }
}

// MARK: - Outbox (persisted)

fileprivate enum HazardOp: Codable, Equatable {
    case upsert(CloudHazard)
    case resolve(String)
}

fileprivate final class HazardOutbox {
    private let fm = FileManager.default
    private let url: URL
    private var cache: [HazardOp] = []

    var hasItems: Bool { !cache.isEmpty }

    init() {
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Hazards", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("outbox.json")
        cache = load()
    }

    func enqueue(_ op: HazardOp) {
        var all = load()
        all.append(op)
        save(all)
        cache = all
    }

    func peek() -> HazardOp? {
        cache = load()
        return cache.first
    }

    func pop() {
        var all = load()
        if !all.isEmpty { all.removeFirst() }
        save(all)
        cache = all
    }

    private func load() -> [HazardOp] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([HazardOp].self, from: data)) ?? []
    }
    private func save(_ ops: [HazardOp]) {
        if let data = try? JSONEncoder().encode(ops) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Mapping

fileprivate extension HazardReport {
    func toCloud() -> CloudHazard {
        CloudHazard(id: id,
                    kind: kind,
                    coordinate: coordinate,
                    severity: severity,
                    confirmations: confirmations,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    expiresAt: expiresAt,
                    status: status,
                    serverTimestamp: Date())
    }
}

// MARK: - DEBUG Fakes for tests

#if DEBUG
public final class HazardRemoteAPIFake: HazardRemoteAPI {
    private var store: [String: CloudHazard] = [:]
    private var updates: [CloudHazard] = []
    private var idx = 0

    public init(seed: [CloudHazard] = []) {
        seed.forEach { store[$0.id] = $0 }
    }

    public func fetchSince(_ since: String?, pageSize: Int) async throws -> (items: [CloudHazard], nextSince: String?) {
        // Emit updates list in small pages
        try await Task.sleep(nanoseconds: 50_000_000)
        guard idx < updates.count else { return ([], nil) }
        let end = min(idx + max(1, pageSize), updates.count)
        let page = Array(updates[idx..<end])
        idx = end
        let token = end < updates.count ? "t\(end)" : nil
        return (page, token)
    }

    public func upsert(_ hazard: CloudHazard) async throws -> CloudHazard {
        let confirmed = CloudHazard(id: hazard.id,
                                    kind: hazard.kind,
                                    coordinate: hazard.coordinate,
                                    severity: hazard.severity,
                                    confirmations: max(hazard.confirmations, (store[hazard.id]?.confirmations ?? 0)),
                                    createdAt: hazard.createdAt,
                                    updatedAt: Date(),
                                    expiresAt: hazard.expiresAt,
                                    status: hazard.status,
                                    serverTimestamp: Date())
        store[confirmed.id] = confirmed
        updates.append(confirmed)
        return confirmed
    }

    public func resolve(id: String) async throws -> CloudHazard {
        guard var h = store[id] else {
            // synthesize for tests
            h = CloudHazard(id: id, kind: .other, coordinate: .init(latitude: 0, longitude: 0), severity: 1, confirmations: 1, createdAt: Date(), updatedAt: Date(), expiresAt: nil, status: .active, serverTimestamp: Date())
        }
        let resolved = CloudHazard(id: h.id,
                                   kind: h.kind,
                                   coordinate: h.coordinate,
                                   severity: h.severity,
                                   confirmations: h.confirmations,
                                   createdAt: h.createdAt,
                                   updatedAt: Date(),
                                   expiresAt: h.expiresAt,
                                   status: .resolved,
                                   serverTimestamp: Date())
        store[resolved.id] = resolved
        updates.append(resolved)
        return resolved
    }
}
#endif
