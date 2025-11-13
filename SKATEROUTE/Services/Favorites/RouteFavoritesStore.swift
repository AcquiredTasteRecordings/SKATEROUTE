// Services/Favorites/RouteFavoritesStore.swift
// Save / rename / share user routes with SwiftData persistence + offline toggle.
// Stores an MKRoute lightweight summary and an encoded polyline blob.
// Duplicate-safe (stable route hash), rename idempotent, and offline pack integration.
// ATT-free. No secrets. DI-friendly. Testable fakes included.

import Foundation
import SwiftData
import Combine
import MapKit
import os.log

// MARK: - Models

@Model
public final class FavoriteRoute {
    @Attribute(.unique) public var id: String               // UUID string
    public var name: String
    public var routeHash: String                            // stable hash for dedupe
    public var distanceMeters: CLLocationDistance
    public var expectedTravelTime: TimeInterval
    public var startName: String?
    public var endName: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var polylineData: Data                           // encoded MKPolyline payload (see encoder below)
    public var bbox: BBox                                   // quick map zoom hint
    public var isOfflineEnabled: Bool                       // corridor tiles requested
    public var offlinePackId: String?                       // returned by OfflineTileFetcher
    public var version: Int

    public init(id: String = UUID().uuidString,
                name: String,
                routeHash: String,
                distanceMeters: CLLocationDistance,
                expectedTravelTime: TimeInterval,
                startName: String?,
                endName: String?,
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                polylineData: Data,
                bbox: BBox,
                isOfflineEnabled: Bool = false,
                offlinePackId: String? = nil,
                version: Int = 1) {
        self.id = id
        self.name = name
        self.routeHash = routeHash
        self.distanceMeters = distanceMeters
        self.expectedTravelTime = expectedTravelTime
        self.startName = startName
        self.endName = endName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.polylineData = polylineData
        self.bbox = bbox
        self.isOfflineEnabled = isOfflineEnabled
        self.offlinePackId = offlinePackId
        self.version = version
    }
}

/// Axis-aligned bounding box for quick camera fit.
public struct BBox: Codable, Hashable {
    public var minLat: Double
    public var minLon: Double
    public var maxLat: Double
    public var maxLon: Double
}

// MARK: - DI seams

    /// Build a social-ready payload for a route (map snapshot + deep link text).
    func buildRouteSharePayload(routeName: String,
                                polyline: MKPolyline,
                                distanceMeters: CLLocationDistance,
                                bbox: BBox) async throws -> SharePayload
}

public protocol OfflineTileFetching {
    /// Prepare corridor tiles for the provided polyline. Returns a stable pack id.
    func prepareCorridorPack(for polyline: MKPolyline,
                             metersBuffer: Double,
                             minZoom: Int,
                             maxZoom: Int) async throws -> String

    /// Remove an existing pack by id (best effort).
    func removePack(id: String) async throws
}

// MARK: - Store

@MainActor
public final class RouteFavoritesStore: ObservableObject {

    public enum State: Equatable { case idle, ready, error(String) }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var favorites: [FavoriteRoute] = []

    public var favoritesPublisher: AnyPublisher<[FavoriteRoute], Never> { $favorites.eraseToAnyPublisher() }

    // DI
    private let modelContext: ModelContext
    private let shareBuilder: SharePayloadBuilding
    private let offline: OfflineTileFetching
    private let log = Logger(subsystem: "com.skateroute", category: "RouteFavoritesStore")

    public init(modelContext: ModelContext,
                shareBuilder: SharePayloadBuilding,
                offline: OfflineTileFetching) {
        self.modelContext = modelContext
        self.shareBuilder = shareBuilder
        self.offline = offline
        // Warm cache
        reload()
    }

    // MARK: Bootstrap

    public func reload() {
        let all = (try? modelContext.fetch(FetchDescriptor<FavoriteRoute>())) ?? []
        favorites = all.sorted { $0.updatedAt > $1.updatedAt }
        state = .ready
    }

    // MARK: Save / Dedupe

    /// Save or return an existing favorite for this MKRoute. Duplicate-safe via routeHash.
    @discardableResult
    public func save(route: MKRoute, suggestedName: String? = nil) throws -> FavoriteRoute {
        // Build a content hash from coordinates + distance to dedupe
        let hash = Self.stableHash(for: route)
        if let existing = try fetchByHash(hash) {
            // Idempotent rename if incoming suggested name differs (non-empty)
            if let name = suggestedName, !name.trimmingCharacters(in: .whitespaces).isEmpty, name != existing.name {
                existing.name = name
                existing.updatedAt = Date(); existing.version += 1
                try modelContext.save()
                reload()
            }
            return existing
        }

        // Encode polyline
        let data = try Self.encode(polyline: route.polyline)
        let bbox = Self.bbox(for: route.polyline)

        let start = route.steps.first?.instructions.isEmpty == false ? route.steps.first?.instructions : route.name // best-effort
        let end = route.steps.last?.instructions

        let fav = FavoriteRoute(name: suggestedName ?? Self.defaultName(for: route),
                                routeHash: hash,
                                distanceMeters: route.distance,
                                expectedTravelTime: route.expectedTravelTime,
                                startName: start,
                                endName: end,
                                polylineData: data,
                                bbox: bbox)

        modelContext.insert(fav)
        try modelContext.save()
        reload()
        return fav
    }

    // MARK: Rename (idempotent)

    public func rename(id: String, newName: String) throws {
        guard let fav = try fetch(id: id) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, fav.name != trimmed else { return }
        fav.name = trimmed
        fav.updatedAt = Date(); fav.version += 1
        try modelContext.save()
        reload()
    }

    // MARK: Delete

    public func remove(id: String) throws {
        guard let fav = try fetch(id: id) else { return }
        // best-effort: tear down offline pack if enabled
        if let pack = fav.offlinePackId {
            Task { try? await offline.removePack(id: pack) }
        }
        modelContext.delete(fav)
        try modelContext.save()
        reload()
    }

    // MARK: Offline toggle

    /// Enable/disable offline tiles for this route. Writes pack id when enabled.
    public func setOfflineEnabled(id: String, enabled: Bool,
                                  corridorMeters: Double = 150,
                                  minZoom: Int = 12,
                                  maxZoom: Int = 17) async throws {
        guard let fav = try fetch(id: id) else { return }
        guard fav.isOfflineEnabled != enabled else { return } // idempotent

        if enabled {
            let poly = try Self.decodePolyline(from: fav.polylineData)
            let packId = try await offline.prepareCorridorPack(for: poly,
                                                               metersBuffer: corridorMeters,
                                                               minZoom: minZoom,
                                                               maxZoom: maxZoom)
            fav.isOfflineEnabled = true
            fav.offlinePackId = packId
        } else {
            if let pack = fav.offlinePackId {
                try await offline.removePack(id: pack)
            }
            fav.isOfflineEnabled = false
            fav.offlinePackId = nil
        }
        fav.updatedAt = Date(); fav.version += 1
        try modelContext.save()
        reload()
    }

    // MARK: Share

    public func buildSharePayload(id: String) async throws -> SharePayloadBuilding.SharePayload {
        guard let fav = try fetch(id: id) else { throw FavoritesError.notFound }
        let poly = try Self.decodePolyline(from: fav.polylineData)
        return try await shareBuilder.buildRouteSharePayload(routeName: fav.name,
                                                             polyline: poly,
                                                             distanceMeters: fav.distanceMeters,
                                                             bbox: fav.bbox)
    }

    // MARK: Fetch helpers

    public func fetch(id: String) throws -> FavoriteRoute? {
        try modelContext.fetch(FetchDescriptor<FavoriteRoute>(predicate: #Predicate { $0.id == id })).first
    }

    private func fetchByHash(_ hash: String) throws -> FavoriteRoute? {
        try modelContext.fetch(FetchDescriptor<FavoriteRoute>(predicate: #Predicate { $0.routeHash == hash })).first
    }

    // MARK: Encoding / Hashing

    /// Encode MKPolyline to a compact Data blob (delta-encoded 1e5 precision, varint).
    /// This is deterministic across runs and platform versions.
    static func encode(polyline: MKPolyline) throws -> Data {
        var data = Data()
        var lastLat = 0
        var lastLon = 0
        polyline.getCoordinates(nil, range: NSRange(location: 0, length: 0)) // no-op to ensure buffer ready
        let count = polyline.pointCount
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        for c in coords {
            let lat = Int64((c.latitude * 1e5).rounded())
            let lon = Int64((c.longitude * 1e5).rounded())
            let dLat = Int64(lat) - Int64(lastLat)
            let dLon = Int64(lon) - Int64(lastLon)
            data.append(varintZigZag(dLat))
            data.append(varintZigZag(dLon))
            lastLat = Int(lat)
            lastLon = Int(lon)
        }
        return data
    }

    static func decodePolyline(from data: Data) throws -> MKPolyline {
        var idx = data.startIndex
        var lat = Int64(0), lon = Int64(0)
        var coords: [CLLocationCoordinate2D] = []
        while idx < data.endIndex {
            let (dLat, a) = try readVarintZigZag(data, start: idx); idx = a
            let (dLon, b) = try readVarintZigZag(data, start: idx); idx = b
            lat += dLat; lon += dLon
            coords.append(CLLocationCoordinate2D(latitude: Double(lat) / 1e5,
                                                 longitude: Double(lon) / 1e5))
        }
        return MKPolyline(coordinates: coords, count: coords.count)
    }

    static func stableHash(for route: MKRoute) -> String {
        // Hash of encoded polyline + rounded distance + rounded expected time ensures dedupe across tiny float jitter.
        let poly = (try? encode(polyline: route.polyline)) ?? Data()
        var hasher = Hasher()
        hasher.combine(poly)
        hasher.combine(Int(route.distance.rounded()))
        hasher.combine(Int(route.expectedTravelTime.rounded()))
        return String(format: "%016llx", hasher.finalize().toUInt64())
    }

    static func bbox(for polyline: MKPolyline) -> BBox {
        let rect = polyline.boundingMapRect
        let sw = MKMapPoint(x: rect.minX, y: rect.maxY).coordinate
        let ne = MKMapPoint(x: rect.maxX, y: rect.minY).coordinate
        return BBox(minLat: min(sw.latitude, ne.latitude),
                    minLon: min(sw.longitude, ne.longitude),
                    maxLat: max(sw.latitude, ne.latitude),
                    maxLon: max(sw.longitude, ne.longitude))
    }

    static func defaultName(for route: MKRoute) -> String {
        let km = route.distance / 1000
        return String(format: NSLocalizedString("route_default_name_km", comment: "e.g., Cruise • %.1f km"), km)
    }

    // MARK: - Varint helpers (LEB128 + zigzag)

    private static func varintZigZag(_ v: Int64) -> Data {
        let zz = (v << 1) ^ (v >> 63)
        var x = UInt64(bitPattern: zz)
        var out = Data()
        while x >= 0x80 {
            out.append(UInt8((x & 0x7F) | 0x80))
            x >>= 7
        }
        out.append(UInt8(x & 0x7F))
        return out
    }

    private static func readVarintZigZag(_ data: Data, start: Data.Index) throws -> (Int64, Data.Index) {
        var idx = start
        var shift: UInt64 = 0
        var result: UInt64 = 0
        while idx < data.endIndex {
            let byte = data[idx]; idx = data.index(after: idx)
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 { break }
            shift += 7
            if shift > 63 { throw FavoritesError.malformedPolyline }
        }
        let zz = Int64(bitPattern: result)
        let v = (zz >> 1) ^ -(zz & 1)
        return (v, idx)
    }
}

// MARK: - Errors

public enum FavoritesError: LocalizedError {
    case notFound
    case malformedPolyline

    public var errorDescription: String? {
        switch self {
        case .notFound: return "Favorite not found."
        case .malformedPolyline: return "Couldn’t decode route path."
        }
    }
}

// MARK: - Private utils

private extension Int {
    func toUInt64() -> UInt64 { UInt64(bitPattern: Int64(self)) }
}

// MARK: - DEBUG Fakes (unit/UI tests)

#if DEBUG
public final class SharePayloadBuilderFake: SharePayloadBuilding {
    public init() {}
    public func buildRouteSharePayload(routeName: String,
                                       polyline: MKPolyline,
                                       distanceMeters: CLLocationDistance,
                                       bbox: BBox) async throws -> SharePayload {
        let url = URL(string: "https://skateroute.app/r/\(routeName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "ride")")!
        return SharePayload(url: url, imageData: nil, text: "\(routeName) • \(Int(distanceMeters)) m")
    }
}

public final class OfflineTileFetcherFake: OfflineTileFetching {
    public init() {}
    public func prepareCorridorPack(for polyline: MKPolyline, metersBuffer: Double, minZoom: Int, maxZoom: Int) async throws -> String {
        return "pack-\(UUID().uuidString)"
    }
    public func removePack(id: String) async throws {}
}
#endif


