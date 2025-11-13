// Services/Offline/TileFetcher.swift
// Extensible, off-by-default offline tile pipeline for maps/elevation/attribution.
// • Corridor-based prefetch for active routes (Mercator tiles), rate-limited + resumable.
// • Writes under CacheManager namespace "Tiles/<providerId>/<z>/<x>/<y>.<ext>" with .meta sidecars.
// • ToS guardrails: explicit allowlist domains, offlineAllowed flag, attribution persisted.
// • Opt-in via DI; never ships with secrets; disabled unless provider + policy pass.
//
// Dependencies (lightweight seams):
//   - CacheManaging (our CacheManager adapter; see protocol below).
//   - RemoteConfigServing (feature kill-switch; optional).
//
// Notes:
//   - This fetcher does not render; it only stages tiles for MapKit snapshotters / overlays to consume.
//   - Designed to keep UI snappy by pre-warming cache along the route corridor to stay within nav budgets.
//   - Elevation tiles supported as binary payloads (e.g., .terrain-rgb / .png); attribution recorded the same way.

import Foundation
import CoreLocation
import Combine
import CryptoKit
import os.log

// MARK: - DI seams

public protocol CacheManaging {
    func url(for keyPath: String, createDirs: Bool) -> URL
    func exists(_ keyPath: String) -> Bool
    func write(_ data: Data, to keyPath: String) throws
    func read(_ keyPath: String) -> Data?
    func remove(_ keyPath: String) throws
}

public protocol RemoteConfigServing {
    var isProfileCloudSyncEnabled: Bool { get } // already used elsewhere; here only presence matters
    // You may also expose a boolean key like "offline.tiles_enabled" via a wrapper if desired.
}

// MARK: - Provider contract

public struct TileProvider: Sendable, Equatable {
    public enum Kind: String, Sendable { case rasterPNG, rasterJPG, vectorPBF, elevationPNG }
    public let id: String                          // e.g., "my-tiles"
    public let baseURLTemplate: String             // e.g., "https://tiles.example.com/{z}/{x}/{y}.png?key={API_KEY}"
    public let kind: Kind
    public let fileExt: String                     // "png", "jpg", "pbf"
    public let attributionHTML: String             // persisted for UI footers / legal page
    public let offlineAllowed: Bool                // ToS flag you must set true to permit offline caching
    public let allowedDomains: [String]            // strict allowlist; otherwise fetcher refuses
    public let headers: [String: String]           // static headers (no secrets; put placeholders & inject at runtime safely)
    public let maxZoom: Int                        // clamp safety
    public let minZoom: Int
    public let cacheTTLSeconds: TimeInterval       // default TTL when server headers absent
    public init(id: String,
                baseURLTemplate: String,
                kind: Kind,
                fileExt: String,
                attributionHTML: String,
                offlineAllowed: Bool,
                allowedDomains: [String],
                headers: [String: String] = [:],
                minZoom: Int = 6,
                maxZoom: Int = 18,
                cacheTTLSeconds: TimeInterval = 7*24*3600) {
        self.id = id
        self.baseURLTemplate = baseURLTemplate
        self.kind = kind
        self.fileExt = fileExt
        self.attributionHTML = attributionHTML
        self.offlineAllowed = offlineAllowed
        self.allowedDomains = allowedDomains
        self.headers = headers
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.cacheTTLSeconds = cacheTTLSeconds
    }
}

// MARK: - Public models

public struct TileCoord: Hashable, Sendable { public let z: Int; public let x: Int; public let y: Int }

public struct PrefetchPlan: Sendable, Equatable {
    public let tiles: [TileCoord]
    public let zooms: ClosedRange<Int>
    public let radiusMeters: Double
    public let approxBytes: Int // rough estimate using historical averages / ext heuristics
}

public struct PrefetchProgress: Sendable, Equatable {
    public let total: Int
    public let completed: Int
    public let cachedHits: Int
    public let bytesWritten: Int
}

public enum TileFetcherError: Error {
    case tilesDisabled
    case providerOfflineNotAllowed
    case providerDomainNotAllowed
    case invalidTemplate
    case cancelled
}

// MARK: - Service

@MainActor
public final class TileFetcher: ObservableObject {

    public enum State: Equatable { case idle, planning, fetching, ready, error(String) }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var lastProgress: PrefetchProgress = .init(total: 0, completed: 0, cachedHits: 0, bytesWritten: 0)
    @Published public private(set) var lastPlan: PrefetchPlan?

    public var progressPublisher: AnyPublisher<PrefetchProgress, Never> { progressSubject.eraseToAnyPublisher() }

    // DI
    private let cache: CacheManaging
    private let provider: TileProvider
    private let remoteConfig: RemoteConfigServing?
    private let log = Logger(subsystem: "com.skateroute", category: "TileFetcher")

    // Net
    private let session: URLSession
    private let rateLimit: Int
    private let allowConstrained: Bool
    private let wifiOnly: Bool

    // Control
    private var cancelFlag = false
    private let progressSubject = PassthroughSubject<PrefetchProgress, Never>()

    // Heuristics per kind
    private var avgBytesPerTile: Int {
        switch provider.kind {
        case .rasterPNG: return 25_000
        case .rasterJPG: return 18_000
        case .vectorPBF: return 8_000
        case .elevationPNG: return 30_000
        }
    }

    public init(cache: CacheManaging,
                provider: TileProvider,
                remoteConfig: RemoteConfigServing? = nil,
                concurrentRequests: Int = 6,
                allowConstrained: Bool = false,
                wifiOnly: Bool = false,
                sessionId: String = "tilesession") {
        self.cache = cache
        self.provider = provider
        self.remoteConfig = remoteConfig
        self.rateLimit = max(1, concurrentRequests)
        self.allowConstrained = allowConstrained
        self.wifiOnly = wifiOnly

        let cfg = URLSessionConfiguration.background(withIdentifier: "com.skateroute.\(sessionId)")
        cfg.allowsConstrainedNetworkAccess = allowConstrained
        cfg.allowsExpensiveNetworkAccess = !wifiOnly
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForResource = 60
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData // we own disk cache
        self.session = URLSession(configuration: cfg)
    }

    // MARK: Public API

    /// Compute tile coverage for a polyline corridor and persist attribution metadata. Returns a plan.
    public func planCorridor(for coordinates: [CLLocationCoordinate2D],
                             radiusMeters: Double,
                             zooms: ClosedRange<Int>) throws -> PrefetchPlan {
        guard provider.offlineAllowed else { throw TileFetcherError.providerOfflineNotAllowed }
        guard isDomainAllowed(provider.baseURLTemplate) else { throw TileFetcherError.providerDomainNotAllowed }

        let zr = ClosedRange(uncheckedBounds: (lower: max(provider.minZoom, zooms.lowerBound),
                                               upper: min(provider.maxZoom, zooms.upperBound)))
        state = .planning

        var set = Set<TileCoord>()
        for z in zr {
            let r = max(1, Int(radiusMeters / metersPerPixel(zoom: z))) // pixels radius ~ 1 tile units ring
            for (a, b) in zip(coordinates, coordinates.dropFirst()) {
                for tc in tilesForSegment(a, b, zoom: z, pixelRadius: r) {
                    set.insert(tc)
                }
            }
        }

        let tiles = Array(set)
        let approx = tiles.count * avgBytesPerTile
        // Write provider metadata for legal
        persistAttributionIfNeeded()

        let plan = PrefetchPlan(tiles: tiles, zooms: zr, radiusMeters: radiusMeters, approxBytes: approx)
        lastPlan = plan
        state = .ready
        return plan
    }

    /// Execute plan with rate limiting and resume support. Safe to call repeatedly; only missing/expired tiles are fetched.
    public func execute(plan: PrefetchPlan) async throws {
        try ensureEnabled()
        state = .fetching
        cancelFlag = false
        var progress = PrefetchProgress(total: plan.tiles.count, completed: 0, cachedHits: 0, bytesWritten: 0)
        lastProgress = progress
        progressSubject.send(progress)

        // Work queue
        let sem = AsyncSemaphore(limit: rateLimit)
        await withTaskGroup(of: Void.self) { group in
            for t in plan.tiles {
                group.addTask { [weak self] in
                    guard let self, !self.cancelFlag else { return }
                    await sem.acquire()
                    defer { sem.release() }
                    do {
                        let wrote = try await self.fetchTileIfNeeded(t)
                        await MainActor.run {
                            var p = progress
                            p.completed += 1
                            if wrote == .cacheHit { p.cachedHits += 1 }
                            if case let .written(bytes) = wrote { p.bytesWritten += bytes }
                            self.lastProgress = p
                            self.progressSubject.send(p)
                        }
                    } catch {
                        // Ignore single-tile failures; they can be refetched later.
                    }
                }
            }
            await group.waitForAll()
        }

        state = .ready
    }

    public func cancel() { cancelFlag = true }

    // MARK: Introspection / reading

    public func cachedURL(for tile: TileCoord) -> URL { cache.url(for: keyPath(for: tile), createDirs: true) }
    public func hasTile(_ t: TileCoord) -> Bool { cache.exists(keyPath(for: t)) }

    // MARK: Internals

    private enum FetchResult { case written(Int), notModified, cacheHit }
    private func fetchTileIfNeeded(_ t: TileCoord) async throws -> FetchResult {
        let key = keyPath(for: t)
        let metaKey = key + ".meta"
        // If present and not expired → hit
        if cache.exists(key), let meta = readMeta(metaKey), !meta.isExpired {
            return .cacheHit
        }

        // Build request
        guard let url = urlForTile(t) else { throw TileFetcherError.invalidTemplate }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        for (k, v) in provider.headers { req.setValue(v, forHTTPHeaderField: k) }
        if let etag = readMeta(metaKey)?.etag {
            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        // Respect cancellation
        if cancelFlag { throw TileFetcherError.cancelled }

        let (data, resp) = try await session.data(for: req, delegate: nil)
        guard let http = resp as? HTTPURLResponse else { return .notModified }

        if http.statusCode == 304, cache.exists(key) {
            // Update expiry from headers if provided
            let newMeta = Meta.from(http: http, fallbackTTL: provider.cacheTTLSeconds, existingETag: readMeta(metaKey)?.etag)
            writeMeta(newMeta, to: metaKey)
            return .notModified
        }

        // Basic OK path
        if (200..<300).contains(http.statusCode) {
            try cache.write(data, to: key)
            let newMeta = Meta.from(http: http, fallbackTTL: provider.cacheTTLSeconds, existingETag: nil)
            writeMeta(newMeta, to: metaKey)
            return .written(data.count)
        }

        // Errors → treat as miss (logged)
        log.notice("Tile HTTP \(http.statusCode) for \(url.absoluteString, privacy: .private)")
        return .notModified
    }

    private func ensureEnabled() throws {
        guard provider.offlineAllowed else { throw TileFetcherError.providerOfflineNotAllowed }
        guard isDomainAllowed(provider.baseURLTemplate) else { throw TileFetcherError.providerDomainNotAllowed }
        // Optional: a global kill-switch could be checked via remoteConfig if exposed.
    }

    private func urlForTile(_ t: TileCoord) -> URL? {
        var s = provider.baseURLTemplate
        s = s.replacingOccurrences(of: "{z}", with: "\(t.z)")
        s = s.replacingOccurrences(of: "{x}", with: "\(t.x)")
        s = s.replacingOccurrences(of: "{y}", with: "\(t.y)")
        return URL(string: s)
    }

    private func keyPath(for t: TileCoord) -> String {
        "Tiles/\(provider.id)/\(t.z)/\(t.x)/\(t.y).\(provider.fileExt)"
    }

    private func persistAttributionIfNeeded() {
        let legalKey = "Tiles/\(provider.id)/ATTRIBUTION.html"
        if !cache.exists(legalKey) {
            try? cache.write(Data(provider.attributionHTML.utf8), to: legalKey)
        }
    }

    private func isDomainAllowed(_ template: String) -> Bool {
        guard let host = URL(string: template.replacingOccurrences(of: "{z}", with: "0").replacingOccurrences(of: "{x}", with: "0").replacingOccurrences(of: "{y}", with: "0"))?.host?.lowercased()
        else { return false }
        return provider.allowedDomains.contains { host.hasSuffix($0.lowercased()) }
    }

    // MARK: Meta (.meta JSON sidecar)

    private struct Meta: Codable {
        let fetchedAt: Date
        let etag: String?
        let expiresAt: Date
        var isExpired: Bool { Date() >= expiresAt }
        static func from(http: HTTPURLResponse, fallbackTTL: TimeInterval, existingETag: String?) -> Meta {
            let now = Date()
            let etag = http.allHeaderFields["Etag"] as? String ?? existingETag
            let maxAge: TimeInterval
            if let cacheControl = (http.allHeaderFields["Cache-Control"] as? String)?.lowercased(),
               let a = cacheControl.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.hasPrefix("max-age=") }),
               let s = a.split(separator: "=").last, let v = TimeInterval(s) {
                maxAge = v
            } else if let expStr = http.allHeaderFields["Expires"] as? String,
                      let expDate = HTTPDateParser.parse(expStr) {
                maxAge = expDate.timeIntervalSince(now)
            } else {
                maxAge = fallbackTTL
            }
            return Meta(fetchedAt: now, etag: etag, expiresAt: now.addingTimeInterval(max(60, maxAge)))
        }
    }

    private func readMeta(_ keyPath: String) -> Meta? {
        guard let data = cache.read(keyPath) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }
    private func writeMeta(_ m: Meta, to keyPath: String) {
        if let data = try? JSONEncoder().encode(m) {
            try? cache.write(data, to: keyPath)
        }
    }

    // MARK: Corridor → tiles

    private func tilesForSegment(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, zoom: Int, pixelRadius: Int) -> [TileCoord] {
        // Sample segment into N points, then union radius tiles around each point.
        let n = max(2, Int(distance(a, b) / max(5.0, metersPerPixel(zoom: zoom) * 4))) // ~every few pixels
        var out = Set<TileCoord>()
        for i in 0...n {
            let t = Double(i) / Double(n)
            let p = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                           longitude: a.longitude + (b.longitude - a.longitude) * t)
            let center = mercTileXY(p, zoom)
            let radiusTiles = max(0, pixelRadius / 256) + 1
            for dx in -radiusTiles...radiusTiles {
                for dy in -radiusTiles...radiusTiles {
                    let tc = TileCoord(z: zoom, x: center.x + dx, y: center.y + dy)
                    out.insert(tc)
                }
            }
        }
        return Array(out)
    }

    private func mercTileXY(_ c: CLLocationCoordinate2D, _ z: Int) -> (x: Int, y: Int) {
        let latRad = c.latitude * .pi / 180
        let n = pow(2.0, Double(z))
        let x = Int(floor((c.longitude + 180.0) / 360.0 * n))
        let y = Int(floor((1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / .pi) / 2.0 * n))
        return (x, y)
    }

    private func metersPerPixel(zoom z: Int, lat: Double = 0) -> Double {
        // Approximate at equator; corridor radius errs on the safe side.
        156543.03392 * cos(lat * .pi / 180) / pow(2.0, Double(z))
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
}

// MARK: - Small helpers

fileprivate final class AsyncSemaphore {
    private let limit: Int
    private var current = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { self.limit = limit }
    func acquire() async {
        if current < limit { current += 1; return }
        await withCheckedContinuation { cont in waiters.append(cont) }
    }
    func release() {
        if let first = waiters.first { waiters.removeFirst(); first.resume() }
        else { current = max(0, current - 1) }
    }
}

fileprivate enum HTTPDateParser {
    static func parse(_ s: String) -> Date? {
        let fmts = ["EEE',' dd MMM yyyy HH':'mm':'ss zzz",
                    "EEEE',' dd-MMM-yy HH':'mm':'ss zzz"]
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
        for f in fmts { df.dateFormat = f; if let d = df.date(from: s) { return d } }
        return nil
    }
}

// MARK: - DEBUG fakes for tests

#if DEBUG
public final class CacheManagerFake: CacheManaging {
    private var store: [String: Data] = [:]
    public init() {}
    public func url(for keyPath: String, createDirs: Bool) -> URL { URL(fileURLWithPath: "/tmp/\(keyPath)") }
    public func exists(_ keyPath: String) -> Bool { store[keyPath] != nil }
    public func write(_ data: Data, to keyPath: String) throws { store[keyPath] = data }
    public func read(_ keyPath: String) -> Data? { store[keyPath] }
    public func remove(_ keyPath: String) throws { store.removeValue(forKey: keyPath) }
}
#endif

// MARK: - Integration notes
// • AppDI: build a TileProvider for your source, set offlineAllowed=true only if ToS allows offline caching. Example:
//     let provider = TileProvider(
//         id: "local-tiles",
//         baseURLTemplate: "https://tiles.example.com/tiles/{z}/{x}/{y}.png",
//         kind: .rasterPNG,
//         fileExt: "png",
//         attributionHTML: "© Example Maps",
//         offlineAllowed: true,
//         allowedDomains: ["tiles.example.com"],
//         headers: ["User-Agent": "SkateRoute/1.0"],
//         minZoom: 10, maxZoom: 18)
//     let fetcher = TileFetcher(cache: CacheManager.shared, provider: provider, concurrentRequests: 6, wifiOnly: true)
//
// • Route prefetch: when the user hits “Start”, compute corridor plan around the chosen route polyline at zooms 14...17 and radius 200–300 m.
//   Execute the plan in background. Progress can feed DiagnosticsView and a subtle HUD.
//
// • Cache consumption: your map snapshotter / overlays should read from CacheManager’s file URLs transparently (via custom URLProtocol or MKTileOverlay with URLTemplate matching the same structure).
//
// • Ethics & ToS: keep offline disabled unless you have explicit permission. Always show attributionHTML somewhere in MapScreen.

// MARK: - Test plan (unit)
// 1) Manifest planning:
//    - Provide a short polyline (two points); plan at zoom 14...15, radius=200 → tiles count > 0; approxBytes == tiles*avgBytes.
// 2) Cache hit rate:
//    - Pre-write a tile & meta not expired → execute(plan) should report cachedHits=1 and no network write (use URLProtocol stub in tests).
// 3) TTL / ETag:
//    - Simulate 304 Not Modified with existing meta → ensures expiry is refreshed; written bytes stay 0.
// 4) ToS guardrails:
//    - provider.offlineAllowed=false → plan/execute throw providerOfflineNotAllowed.
//    - Domain not in allowlist → throws providerDomainNotAllowed.
// 5) Cancellation:
//    - Call cancel() mid-execute; remaining tasks should stop without error-propagation.
// 6) Wi-Fi preference:
//    - Create URLSessionConfiguration with allowsExpensiveNetworkAccess=false when wifiOnly=true (inspect via reflection in a unit test or inject config).
// 7) Elevation tiles:
//    - Use provider.kind=.elevationPNG and ensure file extension + avgBytes heuristic apply; pipeline identical.


