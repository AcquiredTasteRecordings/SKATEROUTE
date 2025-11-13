//  AttributionService.swift
//  SKATEROUTE
//
//  Purpose: Load local attribution tiles (e.g., Resources/attrs-victoria.json),
//  index them, and answer lightweight lookups used by RouteContextBuilder to
//  enrich MKRoute steps with lane bonuses, hazard/legality hints, and a crossings proxy.
//  No UI code. Thread-safe via actor. No network or secrets.
//

import Foundation
import CoreLocation
import os.log

// MARK: - Public Shapes

public struct AttributionAttributes: Sendable, Hashable {
    public let hasBikeLane: Bool?
    public let hazardScore01: Double?
    public let legalityScore01: Double?
    public let crossingsPerKm: Double?
    public init(hasBikeLane: Bool?, hazardScore01: Double?, legalityScore01: Double?, crossingsPerKm: Double?) {
        self.hasBikeLane = hasBikeLane
        self.hazardScore01 = hazardScore01
        self.legalityScore01 = legalityScore01
        self.crossingsPerKm = crossingsPerKm
    }
}

/// Query contract used by RouteContextBuilder.
public protocol AttributionServiceType: Sendable {
    func attributes(near coordinate: CLLocationCoordinate2D) -> AttributionAttributes?
    func attributes(along a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> AttributionAttributes?
    func datasetVersion() -> String
}

// MARK: - Actor

public actor AttributionService: AttributionServiceType {

    // MARK: Internal storage (immutable after init)
    private let log = Logger(subsystem: "com.yourorg.skateroute", category: "attribution")
    private let version: String
    private let indexCellDegrees: Double
    private let buckets: [GridKey: [Feature]] // spatial grid
    private let domainRanges = DomainRanges()  // clamps and normalization sanity

    // MARK: Init

    /// Loads and indexes the bundled attribution dataset (JSON).
    /// - Parameters:
    ///   - resourceName: file name without extension in Resources/ (e.g., "attrs-victoria")
    ///   - indexCellDegrees: grid cell size in degrees; 0.01 ≈ ~1.1 km N-S
    public init(resourceName: String = "attrs-victoria", indexCellDegrees: Double = 0.01) {
        self.indexCellDegrees = max(0.0025, indexCellDegrees) // clamp to avoid tiny cells
        // Load JSON from bundle
        let (meta, features) = Self.loadAndParse(resourceName: resourceName)
        self.version = meta.version
        // Build spatial index
        self.buckets = Self.buildGrid(features: features, cellDeg: self.indexCellDegrees)
        log.debug("Attribution loaded version \(self.version, privacy: .public) with \(features.count, privacy: .public) features in \(self.buckets.count, privacy: .public) buckets")
    }

    // MARK: Public API

    public nonisolated func datasetVersion() -> String { version }

    /// Point query: return merged attributes from features covering the coordinate.
    public func attributes(near coordinate: CLLocationCoordinate2D) -> AttributionAttributes? {
        let candidates = features(covering: coordinate)
        guard !candidates.isEmpty else { return nil }
        return Self.reduce(features: candidates)
    }

    /// Segment query: sample mid-point and end-points, then merge.
    public func attributes(along a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> AttributionAttributes? {
        guard a.isValid && b.isValid else { return nil }
        let mid = CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) * 0.5,
                                         longitude: (a.longitude + b.longitude) * 0.5)
        var merged = [AttributionAttributes]()
        if let aa = await attributes(near: a) { merged.append(aa) }
        if let bb = await attributes(near: b) { merged.append(bb) }
        if let mm = await attributes(near: mid) { merged.append(mm) }
        guard !merged.isEmpty else { return nil }
        return Self.reduce(attributes: merged)
    }

    // MARK: - Indexing & Lookup (actor-isolated helpers)

    private func features(covering coordinate: CLLocationCoordinate2D) -> [Feature] {
        let key = GridKey(coord: coordinate, cellDeg: indexCellDegrees)
        guard let bucket = buckets[key] else { return [] }
        // Distance filter inside the bucket for circle/box shapes
        return bucket.filter { $0.contains(coordinate) }
    }

    // MARK: - Static impl (parsing, indexing, reduction)

    private static func loadAndParse(resourceName: String) -> (Meta, [Feature]) {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json") else {
            assertionFailure("Missing \(resourceName).json in Resources/")
            return (Meta(version: "0.0.0", schemaVersion: 0), [])
        }
        do {
            let data = try Data(contentsOf: url)
            let doc = try JSONDecoder().decode(Document.self, from: data)
            // Basic schema gate to avoid silent drift
            guard doc.schemaVersion >= 1 else {
                assertionFailure("Unsupported schemaVersion: \(doc.schemaVersion)")
                return (doc.meta, [])
            }
            return (doc.meta, doc.features)
        } catch {
            assertionFailure("Failed to parse \(resourceName).json: \(error)")
            return (Meta(version: "0.0.0", schemaVersion: 0), [])
        }
    }

    private static func buildGrid(features: [Feature], cellDeg: Double) -> [GridKey: [Feature]] {
        var grid: [GridKey: [Feature]] = [:]
        grid.reserveCapacity(max(64, features.count / 8))
        for f in features {
            for key in f.coveringKeys(cellDeg: cellDeg) {
                grid[key, default: []].append(f)
            }
        }
        return grid
    }

    private static func reduce(features: [Feature]) -> AttributionAttributes {
        var hasBikeLane: Bool?
        var hazard: Double?
        var legality: Double?
        var crossings: Double?

        for f in features {
            switch f.kind {
            case .bikeLane:
                hasBikeLane = (hasBikeLane ?? false) || (f.boolValue ?? false)
            case .hazard:
                hazard = max(hazard ?? 0, f.clampedValue01())
            case .legality:
                legality = max(legality ?? 0, f.clampedValue01())
            case .crossingsPerKm:
                crossings = max(crossings ?? 0, f.value ?? 0)
            }
        }
        return AttributionAttributes(hasBikeLane: hasBikeLane,
                                     hazardScore01: hazard,
                                     legalityScore01: legality,
                                     crossingsPerKm: crossings)
    }

    private static func reduce(attributes list: [AttributionAttributes]) -> AttributionAttributes {
        var hasBikeLane: Bool?
        var hazard: Double?
        var legality: Double?
        var crossings: Double?

        for a in list {
            if let v = a.hasBikeLane { hasBikeLane = (hasBikeLane ?? false) || v }
            if let v = a.hazardScore01 { hazard = max(hazard ?? 0, v) }
            if let v = a.legalityScore01 { legality = max(legality ?? 0, v) }
            if let v = a.crossingsPerKm { crossings = max(crossings ?? 0, v) }
        }
        return AttributionAttributes(hasBikeLane: hasBikeLane,
                                     hazardScore01: hazard,
                                     legalityScore01: legality,
                                     crossingsPerKm: crossings)
    }
}

// MARK: - JSON Model

private struct Document: Decodable {
    let schemaVersion: Int
    let meta: Meta
    let features: [Feature]
}

private struct Meta: Decodable {
    let version: String
    let generatedAt: String?
    let region: String?
    let source: String?
    let notes: String?
    let schemaVersion: Int
}

private enum Kind: String, Decodable {
    case bikeLane          // boolValue
    case hazard            // value ∈ [0,1]
    case legality          // value ∈ [0,1]
    case crossingsPerKm    // value ≥ 0
}

private enum Shape: String, Decodable {
    case point   // lat, lon, radiusMeters (treat as circle)
    case box     // minLat, minLon, maxLat, maxLon
}

private struct Feature: Decodable, Sendable, Hashable {
    let id: String
    let kind: Kind
    let shape: Shape
    // Common numeric channel
    let value: Double?
    // Common boolean channel
    let boolValue: Bool?
    // Circle params
    let lat: Double?
    let lon: Double?
    let radiusMeters: Double?
    // Box params
    let minLat: Double?
    let minLon: Double?
    let maxLat: Double?
    let maxLon: Double?

    func contains(_ c: CLLocationCoordinate2D) -> Bool {
        switch shape {
        case .point:
            guard let lat, let lon, let r = radiusMeters else { return false }
            let d = CLLocation(latitude: lat, longitude: lon)
                .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            return d <= r
        case .box:
            guard let minLat, let minLon, let maxLat, let maxLon else { return false }
            return c.latitude >= minLat && c.latitude <= maxLat && c.longitude >= minLon && c.longitude <= maxLon
        }
    }

    func clampedValue01() -> Double {
        guard let v = value else { return 0 }
        return max(0, min(1, v))
    }

    func coveringKeys(cellDeg: Double) -> [GridKey] {
        switch shape {
        case .point:
            guard let lat, let lon, let r = radiusMeters else { return [] }
            // Approx bounding box for the circle (cheap + good enough at city scale)
            let dLat = metersToDegreesLatitude(r)
            let dLon = metersToDegreesLongitude(r, atLat: lat)
            let minLat = lat - dLat, maxLat = lat + dLat
            let minLon = lon - dLon, maxLon = lon + dLon
            return GridKey.covering(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon, cellDeg: cellDeg)
        case .box:
            guard let minLat, let minLon, let maxLat, let maxLon else { return [] }
            return GridKey.covering(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon, cellDeg: cellDeg)
        }
    }
}

// MARK: - Spatial Grid

private struct GridKey: Hashable, Sendable {
    let x: Int
    let y: Int

    init(coord: CLLocationCoordinate2D, cellDeg: Double) {
        self.x = Int(floor((coord.longitude + 180.0) / cellDeg))
        self.y = Int(floor((coord.latitude  +  90.0) / cellDeg))
    }

    static func covering(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double, cellDeg: Double) -> [GridKey] {
        let x0 = Int(floor((minLon + 180.0) / cellDeg))
        let x1 = Int(floor((maxLon + 180.0) / cellDeg))
        let y0 = Int(floor((minLat +  90.0) / cellDeg))
        let y1 = Int(floor((maxLat +  90.0) / cellDeg))
        var keys: [GridKey] = []
        keys.reserveCapacity(max(1, (x1 - x0 + 1) * (y1 - y0 + 1)))
        for x in x0...x1 { for y in y0...y1 { keys.append(GridKey(x: x, y: y)) } }
        return keys
    }
}

// MARK: - Utilities

private struct DomainRanges {
    // Placeholders for future clamping/normalization logic if we expand attributes.
}

/// Fast sanity check for coordinates
private extension CLLocationCoordinate2D {
    var isValid: Bool {
        CLLocationCoordinate2DIsValid(self)
        && latitude >= -90 && latitude <= 90
        && longitude >= -180 && longitude <= 180
    }
}

private func metersToDegreesLatitude(_ meters: Double) -> Double {
    meters / 111_320.0
}

private func metersToDegreesLongitude(_ meters: Double, atLat lat: Double) -> Double {
    let metersPerDegree = cos(lat * .pi / 180.0) * 111_320.0
    guard metersPerDegree > 0.0001 else { return 0 }
    return meters / metersPerDegree
}


