// Services/AttributionService.swift
// Step-level metadata for routing and overlays (surface, lanes, hazards…).
// Battery-light, thread-safe, and extensible: local JSON → remote in future.
// Provides single-step and batch APIs, caching with TTL, and composable providers.

import Foundation
import CoreLocation
import MapKit
import OSLog

// MARK: - StepTags dependency
// NOTE: This file assumes `StepTags` exists in your project with at least:
//   init()
//   init(hasProtectedLane: Bool, hasPaintedLane: Bool, surfaceRough: Bool, hazardCount: Int, highwayClass: String?, surface: String?)
// If your StepTags differs, adjust the merge/composition logic below accordingly.

// MARK: - Hashable coordinate key (quantized to 1e-6 deg to keep cache sparse)
private struct CoordinateKey: Hashable, Sendable {
    let latE6: Int32
    let lonE6: Int32
    init(_ c: CLLocationCoordinate2D) {
        latE6 = Int32((c.latitude * 1_000_000).rounded())
        lonE6 = Int32((c.longitude * 1_000_000).rounded())
    }
}

private let log = Logger(subsystem: "com.skateroute.app", category: "Attribution")

// MARK: - Provider protocol

/// Supplies attribute tags for route steps (surface, lanes, hazards, etc.).
/// Implementations should be side-effect-free and battery-friendly.
public protocol StepAttributesProvider: Sendable {
    /// Tags for a single step (best-effort; return neutral tags when unknown).
    func tags(for step: MKRoute.Step) async -> StepTags

    /// Batch variant (default implementation loops serially to keep memory low).
    func tags(for steps: [MKRoute.Step]) async -> [StepTags]
}

public extension StepAttributesProvider {
    func tags(for steps: [MKRoute.Step]) async -> [StepTags] {
        var out: [StepTags] = []
        out.reserveCapacity(steps.count)
        for s in steps { out.append(await tags(for: s)) }
        return out
    }
}

// MARK: - Local (bundled) provider

/// Reads a tiny bundled JSON of attribution points (e.g., Victoria sample),
/// matches the nearest point to each step midpoint within a small radius,
/// and emits `StepTags`. Results are cached with TTL.
public actor LocalAttributionProvider: StepAttributesProvider {

    // MARK: Model

    private struct AttrPoint: Decodable, Sendable {
        let lat: Double
        let lon: Double
        let hasProtectedLane: Bool?
        let hasPaintedLane: Bool?
        let surface: String?
        let surfaceRough: Bool?
        let hazardCount: Int?
        // Optional extra metadata for future use
        let lightingLevel: String?
        let freshnessDays: Int?
    }

    private struct AttrFile: Decodable, Sendable {
        let points: [AttrPoint]
    }

    private struct CacheEntry: Sendable {
        let tags: StepTags
        let stamp: Date
    }

    // MARK: Config

    public struct Config: Sendable, Equatable {
        /// Max distance (m) from step midpoint to accept an attribution.
        public var matchRadiusMeters: CLLocationDistance = 60
        /// Cache entry time-to-live (s). Set 0 to disable TTL.
        public var cacheTTL: TimeInterval = 30 * 60
        /// Max cache size (number of distinct midpoints).
        public var cacheCapacity: Int = 2048
        /// Resource tuple (name/ext) to load from the bundle.
        public var resourceName: String = "attrs-victoria"
        public var resourceExt: String = "json"
        public init() { }
    }

    // MARK: State

    private let cfg: Config
    private var points: [AttrPoint] = []
    private var cache: [CoordinateKey: CacheEntry] = [:]
    private var cacheOrder: [CoordinateKey] = [] // naive LRU list

    // MARK: Init

    /// Initialize and eagerly load the bundled resource (best effort).
    public init(bundle: Bundle = .main, config: Config = .init()) {
        self.cfg = config
        self.points = Self.loadPoints(bundle: bundle,
                                      resourceName: config.resourceName,
                                      resourceExt: config.resourceExt)
        if points.isEmpty {
            log.warning("LocalAttributionProvider loaded 0 points. Provide \(self.cfg.resourceName).\(self.cfg.resourceExt) to enable local attribution.")
        } else {
            log.debug("LocalAttributionProvider loaded \(self.points.count) points.")
        }
    }

    // MARK: Public

    public func tags(for step: MKRoute.Step) async -> StepTags {
        guard let mid = midpoint(of: step.polyline) else { return StepTags() }
        let key = CoordinateKey(mid)

        // Cache hit (respect TTL)
        if let cached = cache[key], !isExpired(cached) {
            return cached.tags
        }

        // Find nearest point
        let midLoc = CLLocation(latitude: mid.latitude, longitude: mid.longitude)
        var best: AttrPoint?
        var bestDist: CLLocationDistance = .greatestFiniteMagnitude

        for p in points {
            let d = midLoc.distance(from: CLLocation(latitude: p.lat, longitude: p.lon))
            if d < bestDist {
                bestDist = d
                best = p
            }
        }

        // Compose tags
        let tags: StepTags
        if let candidate = best, bestDist <= cfg.matchRadiusMeters {
            if let hazards = candidate.hazardCount, hazards > 0 {
                log.debug("Local attr: \(hazards) hazard(s) ~\(Int(bestDist)) m from step midpoint.")
            }
            tags = StepTags(
                hasProtectedLane: candidate.hasProtectedLane ?? false,
                hasPaintedLane:   candidate.hasPaintedLane ?? false,
                surfaceRough:     candidate.surfaceRough ?? false,
                hazardCount:      candidate.hazardCount ?? 0,
                highwayClass:     nil,
                surface:          candidate.surface
            )
        } else {
            tags = StepTags()
        }

        insertCache(key: key, value: tags)
        return tags
    }

    public func tags(for steps: [MKRoute.Step]) async -> [StepTags] {
        // Simple serial map to keep memory predictable; steps are short.
        var out: [StepTags] = []
        out.reserveCapacity(steps.count)
        for s in steps { out.append(await tags(for: s)) }
        return out
    }

    // MARK: Helpers

    private func midpoint(of polyline: MKPolyline) -> CLLocationCoordinate2D? {
        let n = polyline.pointCount
        guard n >= 2 else { return nil }
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: n)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: n))
        // Middle point; cheap and stable (good enough for short steps)
        return coords[n / 2]
    }

    private func isExpired(_ entry: CacheEntry) -> Bool {
        guard cfg.cacheTTL > 0 else { return false }
        return Date().timeIntervalSince(entry.stamp) > cfg.cacheTTL
    }

    private func insertCache(key: CoordinateKey, value: StepTags) {
        cache[key] = CacheEntry(tags: value, stamp: Date())
        cacheOrder.append(key)
        // Naive LRU trim
        if cache.count > cfg.cacheCapacity {
            let drop = cacheOrder.prefix(max(0, cacheOrder.count - cfg.cacheCapacity))
            for k in drop { cache[k] = nil }
            cacheOrder.removeFirst(drop.count)
        }
    }

    private static func loadPoints(bundle: Bundle, resourceName: String, resourceExt: String) -> [AttrPoint] {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExt) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(AttrFile.self, from: data)
            return file.points
        } catch {
            log.error("Failed to read \(resourceName).\(resourceExt): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

// MARK: - Composite provider

/// Composes multiple providers and merges results per step (e.g., remote → local fallback).
public actor CompositeAttributionProvider: StepAttributesProvider {

    private let providers: [StepAttributesProvider]

    /// - Parameter providers: Ordered by precedence (first wins for conflicts).
    public init(providers: [StepAttributesProvider]) {
        self.providers = providers
    }

    public func tags(for step: MKRoute.Step) async -> StepTags {
        // Merge across providers with a deterministic strategy.
        var merged = StepTags()
        for p in providers {
            let t = await p.tags(for: step)
            merged = merge(merged, t)
        }
        return merged
    }

    public func tags(for steps: [MKRoute.Step]) async -> [StepTags] {
        var out: [StepTags] = Array(repeating: StepTags(), count: steps.count)
        // For each provider, merge its batch result into the shared array
        for p in providers {
            let incoming = await p.tags(for: steps)
            for i in 0..<steps.count {
                out[i] = merge(out[i], incoming[i])
            }
        }
        return out
    }

    // Merge policy:
    // - Booleans: OR (true if any provider says true)
    // - hazardCount: max
    // - surface/highwayClass: first non-nil wins (respecting provider order)
    private func merge(_ a: StepTags, _ b: StepTags) -> StepTags {
        StepTags(
            hasProtectedLane: a.hasProtectedLane || b.hasProtectedLane,
            hasPaintedLane:   a.hasPaintedLane   || b.hasPaintedLane,
            surfaceRough:     a.surfaceRough     || b.surfaceRough,
            hazardCount:      max(a.hazardCount, b.hazardCount),
            highwayClass:     a.highwayClass ?? b.highwayClass,
            surface:          a.surface ?? b.surface
        )
    }
}

// MARK: - Test hooks / fakes

/// In-memory fake for unit tests and previews.
public struct StaticAttributionProvider: StepAttributesProvider {
    private let map: [CoordinateKey: StepTags]
    private let radius: CLLocationDistance

    public init(points: [(CLLocationCoordinate2D, StepTags)], matchRadiusMeters: CLLocationDistance = 50) {
        self.map = Dictionary(uniqueKeysWithValues: points.map { (CoordinateKey($0.0), $0.1) })
        self.radius = matchRadiusMeters
    }

    public func tags(for step: MKRoute.Step) async -> StepTags {
        guard let mid = midpoint(of: step.polyline) else { return StepTags() }
        let key = CoordinateKey(mid)
        // If exact key not present, do a cheap linear scan (test scale only)
        if let t = map[key] { return t }
        var best: (CoordinateKey, StepTags)?
        var bestDist = CLLocationDistance.infinity
        for (k, v) in map {
            let a = CLLocation(latitude: Double(k.latE6) / 1_000_000.0,
                               longitude: Double(k.lonE6) / 1_000_000.0)
            let b = CLLocation(latitude: mid.latitude, longitude: mid.longitude)
            let d = a.distance(from: b)
            if d < bestDist { bestDist = d; best = (k, v) }
        }
        if bestDist <= radius, let hit = best { return hit.1 }
        return StepTags()
    }

    public func tags(for steps: [MKRoute.Step]) async -> [StepTags] {
        var out: [StepTags] = []
        out.reserveCapacity(steps.count)
        for s in steps { out.append(await tags(for: s)) }
        return out
    }

    private func midpoint(of polyline: MKPolyline) -> CLLocationCoordinate2D? {
        let n = polyline.pointCount
        guard n >= 2 else { return nil }
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: n)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: n))
        return coords[n / 2]
    }
}

// MARK: - Convenience wiring

public enum AttributionServiceFactory {
    /// Default local-only provider (safe offline).
    public static func `default`(bundle: Bundle = .main) -> StepAttributesProvider {
        LocalAttributionProvider(bundle: bundle)
    }

    /// Composite that prefers remote when available, falls back to local.
    /// Plug in a RemoteAttributionProvider later without touching call sites.
    public static func with(local: StepAttributesProvider,
                            remote: StepAttributesProvider?) -> StepAttributesProvider {
        if let remote { return CompositeAttributionProvider(providers: [remote, local]) }
        return local
    }
}


