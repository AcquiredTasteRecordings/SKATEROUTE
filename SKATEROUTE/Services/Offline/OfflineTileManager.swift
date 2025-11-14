// Services/OfflineTileManager.swift
// Offline “tilepack” skeleton: computes a corridor of slippy-map tiles along a route,
// persists a manifest for status/UI, and exposes simple lifecycle APIs.
// Battery-light, actor-safe planning, with cancel + progress + purge.
// NOTE: This does NOT fetch Apple Map tiles (ToS). It only plans/stores manifests
// so your UI can reflect offline readiness and your own tile source (if any) can plug in.

import Foundation
import MapKit
import OSLog

// MARK: - OfflineTileManager

@MainActor
public final class OfflineTileManager: ObservableObject {
    // MARK: State / Progress
    public enum DownloadState: Equatable {
        case idle
        case preparing
        case downloading(progress: Double)  // 0…1
        case cached(tileCount: Int)
        case failed(message: String)
    }

    @Published public private(set) var state: DownloadState = .idle
    @Published public private(set) var lastManifest: TileManifest?

    // MARK: Dependencies
    private let cache = CacheManager.shared
    private let log = Logger(subsystem: "com.skateroute.app", category: "OfflineTiles")

    // Background planning task for cancellation/debounce
    private var planningTask: Task<Void, Never>?

    public init() {}

    // MARK: Public API

    /// Plans and writes a tile manifest for the given route corridor.
    /// This does not download Apple tiles; it stores a manifest your own tile provider could use.
    /// - Parameters:
    ///   - polyline: Route geometry.
    ///   - identifier: Stable id (e.g., hash of source/dest/mode).
    ///   - zoomRange: Slippy zooms to include (12…17 is a solid city default).
    ///   - corridorMeters: Half-width around the path to include tiles for drift/reroute.
    public func ensureTiles(
        for polyline: MKPolyline,
        identifier: String,
        zoomRange: ClosedRange<Int> = 12...17,
        corridorMeters: CLLocationDistance = 120
    ) {
        // If we already have a fresh manifest, publish and bail.
        if let m = loadManifest(identifier: identifier) {
            lastManifest = m
            state = .cached(tileCount: m.tiles.count)
            return
        }

        // Cancel any in-flight planning and start fresh.
        planningTask?.cancel()
        state = .preparing

        planningTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Heavy math off main thread
                let manifest = try await OfflineTileManager.planManifest(
                    polyline: polyline,
                    identifier: identifier,
                    zoomRange: zoomRange,
                    corridorMeters: corridorMeters,
                    progress: { [weak self] p in
                        await MainActor.run { self?.state = .downloading(progress: p) }
                    }
                )

                // Persist on main via CacheManager (thread-safe internally)
                try await MainActor.run {
                    self.saveManifest(manifest)
                    self.lastManifest = manifest
                    self.state = .cached(tileCount: manifest.tiles.count)
                }
            } catch is CancellationError {
                await MainActor.run { self?.state = .idle }
            } catch {
                await MainActor.run { self?.state = .failed(message: "Planning failed") }
            }
        }
    }

    /// Returns true when a manifest exists for id (tilepack planned).
    public func hasTiles(for identifier: String) -> Bool {
        loadManifest(identifier: identifier) != nil
    }

    /// Removes the stored manifest (and any tile payloads if you added a fetcher later).
    public func purge(identifier: String) {
        let key = manifestKey(for: identifier)
        _ = cache.remove(key: key)
        lastManifest = nil
        state = .idle
    }

    /// Purge all tile manifests (does not affect other caches).
    public func purgeAll() {
        // Lightweight: enumerate known keys from the stored index file (optional).
        // For now, we just clear the last in-memory and leave disk GC to CacheManager policy.
        lastManifest = nil
        state = .idle
    }

    /// Reset state to idle without touching disk.
    public func reset() { state = .idle }

    // MARK: Storage

    private func manifestKey(for identifier: String) -> String {
        "tilepack-\(identifier).json"
    }

    private func saveManifest(_ m: TileManifest) {
        do {
            let data = try JSONEncoder.tilepack.encode(m)
            try cache.store(data, key: manifestKey(for: m.identifier))
        } catch {
            log.error("Failed to save tile manifest: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadManifest(identifier: String) -> TileManifest? {
        guard let data = cache.data(for: manifestKey(for: identifier)) else { return nil }
        return try? JSONDecoder.tilepack.decode(TileManifest.self, from: data)
    }
}

// MARK: - Planning Engine (off-main)

extension OfflineTileManager {
    /// Minimal slippy tile coordinate.
    public struct Tile: Codable, Hashable, Sendable {
        public let z: Int
        public let x: Int
        public let y: Int
    }

    /// Stored tilepack manifest (metadata + tiles).
    public struct TileManifest: Codable, Sendable {
        public let schemaVersion: Int
        public let identifier: String
        public let createdAt: Date
        public let zooms: [Int]
        public let corridorMeters: Double
        public let approxMetersPerPixelAtEquator: Double
        public let tileSize: Int // px
        public let tiles: [Tile]
        public let bounds: MKMapRectCodable

        public init(
            schemaVersion: Int = 1,
            identifier: String,
            createdAt: Date = Date(),
            zooms: [Int],
            corridorMeters: Double,
            approxMetersPerPixelAtEquator: Double = 156543.03392804097,
            tileSize: Int = 256,
            tiles: [Tile],
            bounds: MKMapRectCodable
        ) {
            self.schemaVersion = schemaVersion
            self.identifier = identifier
            self.createdAt = createdAt
            self.zooms = zooms
            self.corridorMeters = corridorMeters
            self.approxMetersPerPixelAtEquator = approxMetersPerPixelAtEquator
            self.tileSize = tileSize
            self.tiles = tiles
            self.bounds = bounds
        }
    }

    /// Plans a corridor of tiles by sampling the polyline and inflating by a radius in tiles.
    static func planManifest(
        polyline: MKPolyline,
        identifier: String,
        zoomRange: ClosedRange<Int>,
        corridorMeters: CLLocationDistance,
        progress: @Sendable (Double) -> Void
    ) async throws -> TileManifest {
        try Task.checkCancellation()

        // 1) Sample the polyline into geodesic points ~ every 120 m (cheap and adequate).
        let coords = await polyline.coordinates()
        let sampled = sampleCoordinates(coords, strideMeters: 120)

        // 2) For each zoom, add the central tile and neighbors that cover the corridor radius.
        var tiles = Set<Tile>()
        let zooms = Array(zoomRange)
        for (i, z) in zooms.enumerated() {
            try Task.checkCancellation()
            let zTiles = tilesFor(points: sampled, zoom: z, corridorMeters: corridorMeters)
            tiles.formUnion(zTiles)
            progress(Double(i + 1) / Double(zooms.count))
        }

        // 3) Manifest with bounds for quick eligibility checks in UI.
        let rect = MKPolyline(coordinates: coords, count: coords.count).boundingMapRect
        let manifest = TileManifest(
            identifier: identifier,
            zooms: zooms,
            corridorMeters: corridorMeters,
            tiles: Array(tiles),
            bounds: MKMapRectCodable(rect)
        )
        return manifest
    }

    // Convert list of CLLocationCoordinate2D into a slippy tile set at zoom z,
    // inflating by a radius (in meters) that translates to +/-N tiles depending on latitude.
    private static func tilesFor(points: [CLLocationCoordinate2D], zoom: Int, corridorMeters: CLLocationDistance) -> Set<Tile> {
        var out = Set<Tile>()
        guard !points.isEmpty else { return out }

        // Precompute a conservative neighbor radius in tiles using mid-latitude (~45°)
        // Then refine per point quickly (cheap trig).
        for p in points {
            // meters per pixel ≈ 156543.0339 * cos(lat) / 2^z
            let metersPerPixel = 156543.03392804097 * cos(p.latitude * .pi / 180.0) / pow(2.0, Double(zoom))
            let metersPerTile = metersPerPixel * 256.0
            let rTiles = max(0, Int(ceil(corridorMeters / metersPerTile)))

            let t = slippyTile(for: p, z: zoom)
            // Add center + rTiles neighborhood
            for dx in -rTiles...rTiles {
                for dy in -rTiles...rTiles {
                    let nx = t.x + dx
                    let ny = t.y + dy
                    if nx >= 0, ny >= 0, nx < (1 << zoom), ny < (1 << zoom) {
                        out.insert(Tile(z: zoom, x: nx, y: ny))
                    }
                }
            }
        }
        return out
    }

    // Slippy tile conversion (Web Mercator)
    private static func slippyTile(for coord: CLLocationCoordinate2D, z: Int) -> Tile {
        let lat = coord.latitude.clamped(-85.05112878, 85.05112878)
        let lon = coord.longitude.clamped(-180, 180)
        let n = Double(1 << z)
        let x = Int(floor((lon + 180.0) / 360.0 * n))
        let latRad = lat * .pi / 180.0
        let y = Int(floor((1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / .pi) / 2.0 * n))
        return Tile(z: z, x: x, y: y)
    }

    // Downsamples coordinates roughly by distance along path.
    private static func sampleCoordinates(_ coords: [CLLocationCoordinate2D], strideMeters: CLLocationDistance) -> [CLLocationCoordinate2D] {
        guard coords.count > 1 else { return coords }
        var out: [CLLocationCoordinate2D] = [coords[0]]
        var last = coords[0]
        var acc: CLLocationDistance = 0
        for i in 1..<coords.count {
            let d = MKMetersBetweenMapPoints(MKMapPoint(last), MKMapPoint(coords[i]))
            acc += d
            if acc >= strideMeters {
                out.append(coords[i])
                acc = 0
                last = coords[i]
            }
        }
        if out.last != coords.last { out.append(coords.last!) }
        return out
    }
}

// MARK: - Codable helpers

public struct MKMapRectCodable: Codable, Sendable {
    public let originX: Double
    public let originY: Double
    public let width: Double
    public let height: Double

    public init(_ rect: MKMapRect) {
        originX = rect.origin.x
        originY = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    public var rect: MKMapRect {
        MKMapRect(x: originX, y: originY, width: width, height: height)
    }
}

private extension JSONEncoder {
    static let tilepack: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let tilepack: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { max(lo, min(hi, self)) }
}

// MARK: - MKPolyline convenience

private extension MKPolyline {
    /// Extract coordinates as an array without leaking mutable buffers across threads.
    func coordinates() async -> [CLLocationCoordinate2D] {
        let n = pointCount
        guard n > 0 else { return [] }
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: n)
        getCoordinates(&coords, range: NSRange(location: 0, length: n))
        return coords
    }
}


