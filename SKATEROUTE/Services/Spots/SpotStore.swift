// Services/Spots/SpotStore.swift
// CRUD + geo queries for SkateSpot with local SwiftData cache, remote sync, and stable clustering.
// MapKit-first. No tracking. No secrets. Ready for DI & unit tests.

import Foundation
import Combine
import SwiftData
import MapKit
import os.log

// MARK: - Contracts (DI seams)

public protocol SpotRemoteAPI {
    /// Upsert a spot (create or edit). Server returns authoritative copy and serverUpdatedAt.
    func upsert(_ spot: CloudSkateSpot) async throws -> CloudSkateSpot
    /// Moderation actions (approve/reject/archive)
    func moderate(spotId: String, action: SpotModerationAction) async throws -> CloudSkateSpot
    /// Incremental sync newer than the since token (opaque)
    func fetchSince(_ since: String?, pageSize: Int) async throws -> (items: [CloudSkateSpot], nextSince: String?)
}

public enum SpotModerationAction: String, Codable { case approve, reject, archive }

/// Cloud payload mirrored by local model (lives on server adapter boundary)
public struct CloudSkateSpot: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let category: String
    public let coordinate: CLLocationCoordinate2D
    public let createdAt: Date
    public let updatedAt: Date
    public let status: SpotStatus
    public let serverTimestamp: Date
    public init(id: String, title: String, subtitle: String?, category: String, coordinate: CLLocationCoordinate2D, createdAt: Date, updatedAt: Date, status: SpotStatus, serverTimestamp: Date) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.category = category; self.coordinate = coordinate; self.createdAt = createdAt; self.updatedAt = updatedAt; self.status = status; self.serverTimestamp = serverTimestamp
    }
}

// MARK: - Local Model (SwiftData)
// NOTE: Your repo should already declare Models/SkateSpot.swift. If not, this @Model is compatible.

@Model
public final class SkateSpot {
    @Attribute(.unique) public var id: String
    public var title: String
    public var subtitle: String?
    public var category: String
    public var lat: Double
    public var lon: Double
    public var createdAt: Date
    public var updatedAt: Date
    public var status: SpotStatus          // pending/active/rejected/archived
    public var lastSyncedAt: Date?
    public var version: Int

    public init(id: String,
                title: String,
                subtitle: String? = nil,
                category: String,
                lat: Double,
                lon: Double,
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                status: SpotStatus = .pending,
                lastSyncedAt: Date? = nil,
                version: Int = 1) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.category = category
        self.lat = lat; self.lon = lon; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.status = status; self.lastSyncedAt = lastSyncedAt; self.version = version
    }

    public var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

public enum SpotStatus: String, Codable, CaseIterable { case pending, active, rejected, archived }

// MARK: - Cluster DTO for Map overlays

public struct SpotCluster: Identifiable, Hashable {
    public let id: String             // stable across frames (grid key)
    public let coordinate: CLLocationCoordinate2D
    public let count: Int
    public let spotIds: [String]
    public let categories: [String: Int] // histogram for legend/badges
}

// MARK: - Store

@MainActor
public final class SpotStore: ObservableObject {

    public enum State: Equatable {
        case idle, loading, ready, error(String)
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var clusters: [SpotCluster] = []
    @Published public private(set) var spotsInView: [SkateSpot] = []

    public var clustersPublisher: AnyPublisher<[SpotCluster], Never> { $clusters.eraseToAnyPublisher() }
    public var spotsPublisher: AnyPublisher<[SkateSpot], Never> { $spotsInView.eraseToAnyPublisher() }

    // DI
    private let modelContext: ModelContext
    private let remote: SpotRemoteAPI
    private let log = Logger(subsystem: "com.skateroute", category: "SpotStore")

    // Pagination + cache
    private var sinceToken: String?
    private var isSyncing = false

    // Spatial index
    private let index = SpotSpatialIndex()
    // Snapshot of all locally visible (status==active) records keyed by id
    private var activeSpots: [String: SkateSpot] = [:]

    public init(modelContext: ModelContext, remote: SpotRemoteAPI) {
        self.modelContext = modelContext
        self.remote = remote
        // Warm from disk
        rebuildActiveIndex()
    }

    // MARK: Bootstrap & Sync

    public func load() async {
        state = .loading
        rebuildActiveIndex()
        state = .ready
        // Opportunistic incremental sync
        await syncIfNeeded()
    }

    public func syncIfNeeded(pageSize: Int = 100) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            var next = sinceToken
            var mutated = false
            repeat {
                let page = try await remote.fetchSince(next, pageSize: pageSize)
                next = page.nextSince
                if !page.items.isEmpty {
                    for cloud in page.items {
                        mutated = true
                        applyRemote(cloud)
                    }
                    try modelContext.save()
                }
            } while next != nil

            if mutated { rebuildActiveIndex() }
            sinceToken = next ?? sinceToken // keep last known
        } catch {
            log.error("Spot sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: CRUD

    @discardableResult
    public func addSpot(title: String,
                        subtitle: String?,
                        category: String,
                        coordinate: CLLocationCoordinate2D) async throws -> SkateSpot {
        let id = UUID().uuidString
        let now = Date()
        let local = SkateSpot(id: id,
                              title: title,
                              subtitle: subtitle,
                              category: category,
                              lat: coordinate.latitude,
                              lon: coordinate.longitude,
                              createdAt: now,
                              updatedAt: now,
                              status: .pending,
                              lastSyncedAt: nil,
                              version: 1)
        modelContext.insert(local)
        try modelContext.save()
        // Write-through: optimistic local add, then remote upsert
        do {
            let confirmed = try await remote.upsert(local.toCloud())
            applyRemote(confirmed)
            try modelContext.save()
            rebuildActiveIndex()
        } catch {
            // Stay pending locally; DiagnosticsView can show unsynced state
            log.notice("Add spot pending sync: \(error.localizedDescription, privacy: .public)")
        }
        return local
    }

    public func updateSpot(id: String,
                           title: String? = nil,
                           subtitle: String? = nil,
                           category: String? = nil,
                           coordinate: CLLocationCoordinate2D? = nil,
                           status: SpotStatus? = nil) async throws {
        guard let spot = try fetchLocal(id: id) else { return }
        var changed = false
        let prevCoord = spot.coordinate

        if let title, title != spot.title { spot.title = title; changed = true }
        if let subtitle, subtitle != spot.subtitle { spot.subtitle = subtitle; changed = true }
        if let category, category != spot.category { spot.category = category; changed = true }
        if let c = coordinate, (c.latitude != spot.lat || c.longitude != spot.lon) {
            spot.lat = c.latitude; spot.lon = c.longitude; changed = true
        }
        if let status, status != spot.status { spot.status = status; changed = true }

        guard changed else { return }
        spot.updatedAt = Date(); spot.version += 1
        try modelContext.save()

        // If moved, reindex immediately so the map reacts
        if coordinate != nil || status != nil {
            rebuildActiveIndex()
        }

        // Remote upsert (best-effort)
        do {
            let confirmed = try await remote.upsert(spot.toCloud())
            applyRemote(confirmed)
            try modelContext.save()
            rebuildActiveIndex()
        } catch {
            log.notice("Update spot pending sync: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func moderate(id: String, action: SpotModerationAction) async throws {
        do {
            let confirmed = try await remote.moderate(spotId: id, action: action)
            applyRemote(confirmed)
            try modelContext.save()
            rebuildActiveIndex()
        } catch {
            log.error("Moderation failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: Geo Queries & Clustering

    /// Returns de-duplicated active spots within the requested region (fast: grid-indexed).
    public func query(in region: MKCoordinateRegion) -> [SkateSpot] {
        let ids = index.query(region: region)
        let out = ids.compactMap { activeSpots[$0] }
        spotsInView = out
        return out
    }

    /// Builds stable clusters for a given region + zoom (MapKit zoom hint). Emits into `clusters`.
    /// - Parameter zoomLevel: typical range 3...20 (derived from MapKit camera). We accept any Double.
    public func clustersFor(region: MKCoordinateRegion, zoomLevel: Double) -> [SpotCluster] {
        let ids = index.query(region: region)
        let pts: [(id: String, coord: CLLocationCoordinate2D, category: String)] = ids.compactMap {
            guard let s = activeSpots[$0] else { return nil }
            return (s.id, s.coordinate, s.category)
        }
        let buckets = index.bucketize(points: pts, region: region, zoom: zoomLevel)
        let out: [SpotCluster] = buckets.map { bucket in
            let centroid = index.centroid(of: bucket.points)
            let hist = Dictionary(grouping: bucket.points, by: { $0.category }).mapValues(\.count)
            return SpotCluster(id: bucket.key, coordinate: centroid, count: bucket.points.count, spotIds: bucket.points.map(\.id), categories: hist)
        }
        clusters = out
        return out
    }

    // MARK: Internals

    private func fetchLocal(id: String) throws -> SkateSpot? {
        try modelContext.fetch(FetchDescriptor<SkateSpot>(predicate: #Predicate { $0.id == id })).first
    }

    private func applyRemote(_ cloud: CloudSkateSpot) {
        // Merge with server timestamp bias
        let local = try? fetchLocal(id: cloud.id)
        if let l = local {
            let skew: TimeInterval = 2.0
            // If local is strictly newer than server, keep local (will re-sync later)
            if l.updatedAt > cloud.serverTimestamp.addingTimeInterval(skew) { return }
            l.title = cloud.title
            l.subtitle = cloud.subtitle
            l.category = cloud.category
            l.lat = cloud.coordinate.latitude
            l.lon = cloud.coordinate.longitude
            l.status = cloud.status
            l.updatedAt = max(l.updatedAt, cloud.updatedAt)
            l.version = max(l.version, l.version + 1)
            l.lastSyncedAt = Date()
        } else {
            let s = SkateSpot(id: cloud.id,
                              title: cloud.title,
                              subtitle: cloud.subtitle,
                              category: cloud.category,
                              lat: cloud.coordinate.latitude,
                              lon: cloud.coordinate.longitude,
                              createdAt: cloud.createdAt,
                              updatedAt: cloud.updatedAt,
                              status: cloud.status,
                              lastSyncedAt: Date(),
                              version: 1)
            modelContext.insert(s)
        }
    }

    private func rebuildActiveIndex() {
        // Load all active spots
        let all = (try? modelContext.fetch(FetchDescriptor<SkateSpot>())) ?? []
        activeSpots = Dictionary(uniqueKeysWithValues: all.filter { $0.status == .active }.map { ($0.id, $0) })
        index.rebuild(with: all.filter { $0.status == .active }.map { ($0.id, $0.coordinate, $0.category) })
    }
}

// MARK: - Spatial Index (grid + stable bucket keys)

fileprivate final class SpotSpatialIndex {

    struct Point {
        let id: String
        let coord: CLLocationCoordinate2D
        let category: String
    }

    private var points: [Point] = []
    private var idToPoint: [String: Point] = [:]

    func rebuild(with entries: [(String, CLLocationCoordinate2D, String)]) {
        points = entries.map { Point(id: $0.0, coord: $0.1, category: $0.2) }
        idToPoint = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
    }

    func query(region: MKCoordinateRegion) -> [String] {
        guard !points.isEmpty else { return [] }
        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLon = normalizedLon(region.center.longitude - region.span.longitudeDelta / 2)
        let maxLon = normalizedLon(region.center.longitude + region.span.longitudeDelta / 2)
        var ids: [String] = []

        if crossesAntimeridian(minLon: minLon, maxLon: maxLon) {
            // Two ranges: [-180..maxLon] U [minLon..180]
            for p in points where p.coord.latitude >= minLat && p.coord.latitude <= maxLat {
                let lon = normalizedLon(p.coord.longitude)
                if lon <= maxLon || lon >= minLon { ids.append(p.id) }
            }
        } else {
            for p in points where p.coord.latitude >= minLat && p.coord.latitude <= maxLat {
                let lon = normalizedLon(p.coord.longitude)
                if lon >= minLon && lon <= maxLon { ids.append(p.id) }
            }
        }
        return ids
    }

    // Stable bucketing per zoom using a mercator-like grid
    func bucketize(points: [(id: String, coord: CLLocationCoordinate2D, category: String)],
                   region: MKCoordinateRegion,
                   zoom: Double) -> [Bucket] {
        guard !points.isEmpty else { return [] }

        // Choose grid size (cells across viewport) to target ~64pt clusters regardless of device scale.
        // Heuristic: more cells when zoomed out. Clamp for stability.
        let cellsAcross = max(8, min(64, Int( pow(2.0, max(0, 6 - (zoom - 3) / 3)) )))
        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLon = normalizedLon(region.center.longitude - region.span.longitudeDelta / 2)
        let maxLon = normalizedLon(region.center.longitude + region.span.longitudeDelta / 2)

        // Handle anti-meridian by mapping longitudes into a continuous 0..360 domain anchored to minLon
        func lonToU(_ lon: Double) -> Double {
            let a = normalizedLon(lon)
            let ref = minLon
            let delta = a - ref
            return (delta < 0 ? delta + 360.0 : delta)
        }

        let latHeight = max(1e-6, maxLat - minLat)
        let lonWidth  = max(1e-6, (maxLon >= minLon ? (maxLon - minLon) : (maxLon + 360.0 - minLon)))

        var buckets: [String: [Point]] = [:]

        for t in points {
            let u = lonToU(t.coord.longitude) / lonWidth // 0..1
            let v = (t.coord.latitude - minLat) / latHeight // 0..1
            let gx = max(0, min(cellsAcross - 1, Int(Double(cellsAcross) * u)))
            let gy = max(0, min(cellsAcross - 1, Int(Double(cellsAcross) * v)))
            let key = "z\(Int(zoom.rounded(.toNearestOrEven)))-\(gx)x\(gy)"
            buckets[key, default: []].append(Point(id: t.id, coord: t.coord, category: t.category))
        }

        return buckets.map { Bucket(key: $0.key, points: $0.value) }
    }

    func centroid(of pts: [Point]) -> CLLocationCoordinate2D {
        guard !pts.isEmpty else { return CLLocationCoordinate2D(latitude: 0, longitude: 0) }
        var x = 0.0, y = 0.0, z = 0.0
        for p in pts {
            let lat = p.coord.latitude * .pi / 180
            let lon = p.coord.longitude * .pi / 180
            x += cos(lat) * cos(lon)
            y += cos(lat) * sin(lon)
            z += sin(lat)
        }
        let total = Double(pts.count)
        x /= total; y /= total; z /= total
        let lon = atan2(y, x)
        let hyp = sqrt(x*x + y*y)
        let lat = atan2(z, hyp)
        return CLLocationCoordinate2D(latitude: lat * 180 / .pi, longitude: lon * 180 / .pi)
    }

    struct Bucket { let key: String; let points: [Point] }

    private func normalizedLon(_ lon: Double) -> Double {
        var L = lon
        while L < -180 { L += 360 }
        while L >  180 { L -= 360 }
        return L
    }
    private func crossesAntimeridian(minLon: Double, maxLon: Double) -> Bool { maxLon < minLon }
}

// MARK: - Mapping helpers

fileprivate extension SkateSpot {
    func toCloud() -> CloudSkateSpot {
        CloudSkateSpot(id: id,
                       title: title,
                       subtitle: subtitle,
                       category: category,
                       coordinate: coordinate,
                       createdAt: createdAt,
                       updatedAt: updatedAt,
                       status: status,
                       serverTimestamp: Date())
    }
}

// MARK: - DEBUG Fakes for tests

#if DEBUG
public final class SpotRemoteAPIFake: SpotRemoteAPI {
    private var store: [String: CloudSkateSpot] = [:]
    private var updates: [CloudSkateSpot] = []
    private var tokenIdx: Int = 0

    public init(seed: [CloudSkateSpot] = []) {
        seed.forEach { store[$0.id] = $0 }
    }

    public func upsert(_ spot: CloudSkateSpot) async throws -> CloudSkateSpot {
        let confirmed = CloudSkateSpot(id: spot.id,
                                       title: spot.title,
                                       subtitle: spot.subtitle,
                                       category: spot.category,
                                       coordinate: spot.coordinate,
                                       createdAt: spot.createdAt,
                                       updatedAt: Date(),
                                       status: spot.status == .pending ? .active : spot.status,
                                       serverTimestamp: Date())
        store[confirmed.id] = confirmed
        updates.append(confirmed)
        return confirmed
    }

    public func moderate(spotId: String, action: SpotModerationAction) async throws -> CloudSkateSpot {
        guard var s = store[spotId] else { throw URLError(.badServerResponse) }
        switch action {
        case .approve: s = CloudSkateSpot(id: s.id, title: s.title, subtitle: s.subtitle, category: s.category, coordinate: s.coordinate, createdAt: s.createdAt, updatedAt: Date(), status: .active, serverTimestamp: Date())
        case .reject: s = CloudSkateSpot(id: s.id, title: s.title, subtitle: s.subtitle, category: s.category, coordinate: s.coordinate, createdAt: s.createdAt, updatedAt: Date(), status: .rejected, serverTimestamp: Date())
        case .archive: s = CloudSkateSpot(id: s.id, title: s.title, subtitle: s.subtitle, category: s.category, coordinate: s.coordinate, createdAt: s.createdAt, updatedAt: Date(), status: .archived, serverTimestamp: Date())
        }
        store[s.id] = s; updates.append(s); return s
    }

    public func fetchSince(_ since: String?, pageSize: Int) async throws -> (items: [CloudSkateSpot], nextSince: String?) {
        // Emit any pending updates in small pages with opaque tokens
        let all = updates
        guard tokenIdx < all.count else { return ([], nil) }
        let end = min(all.count, tokenIdx + max(1, pageSize))
        let page = Array(all[tokenIdx..<end])
        tokenIdx = end
        let token = (end < all.count) ? "t\(end)" : nil
        return (page, token)
    }
}
#endif
