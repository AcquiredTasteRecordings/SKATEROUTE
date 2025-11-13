// Services/Challenges/LeaderboardService.swift
// City/global leaderboards with deterministic pagination and anti-cheat validation.
// Read-only client that fetches boards, validates, sorts (score desc; tie-break = earliest timestamp),
// and exposes stable page cursors. Coarse reverse-geocode derives the city key (privacy-first).
// No tracking, no ATT. DI-friendly; includes DEBUG fakes for tests.

import Foundation
import Combine
import CoreLocation
import MapKit
import os.log

// MARK: - Public Models

public struct LeaderboardEntry: Codable, Hashable, Identifiable {
    public let id: String                  // stable server id for the *entry* (not user id)
    public let userId: String
    public let displayName: String
    public let cityKey: String?            // server-provided city key
    public let distanceMeters: Double
    public let movesCount: Int             // number of rides contributing
    public let achievedAt: Date            // when the shown distance was reached (used for tie-break)
    public let polylineSummary: PolylineSummary? // optional for anti-cheat
    public let premiumFlag: Bool?          // server-side marker; must NOT influence score client-side
    public let avatarURL: URL?             // optional; can be shown in UI

    public var idStr: String { id }        // convenience

    public init(id: String, userId: String, displayName: String,
                cityKey: String?, distanceMeters: Double, movesCount: Int,
                achievedAt: Date, polylineSummary: PolylineSummary?, premiumFlag: Bool?, avatarURL: URL?) {
        self.id = id; self.userId = userId; self.displayName = displayName
        self.cityKey = cityKey; self.distanceMeters = distanceMeters; self.movesCount = movesCount
        self.achievedAt = achievedAt; self.polylineSummary = polylineSummary
        self.premiumFlag = premiumFlag; self.avatarURL = avatarURL
    }
}

/// Minimal geometry info for anti-cheat. Server can send low-res to keep payload tiny.
public struct PolylineSummary: Codable, Hashable {
    public let encoded: String         // Google-style or our own; client decodes to rough coords
    public let reportedMeters: Double  // what server says total length is
    public let elapsedSeconds: Double  // total time
}

// MARK: - DI seams

public protocol LeaderboardRemoteAPI {
    /// Fetch a raw page for scope with an opaque cursor. The server can return more than requested; client will filter.
    func fetch(scope: BoardScope, pageSize: Int, cursor: String?) async throws -> (items: [LeaderboardEntry], nextCursor: String?)
}

public protocol CoarseGeocoding {
    /// Reverse-geocode a coordinate into a coarse, privacy-friendly city key (e.g., "us-san-francisco").
    func cityKey(for coordinate: CLLocationCoordinate2D) async throws -> String
}

public protocol PolylineDecoding {
    /// Decode polyline summary into coordinates (rough; 1e5 precision ok).
    func decode(_ encoded: String) -> [CLLocationCoordinate2D]
}

// MARK: - Anti-cheat policy (pure + testable)

public struct AntiCheatPolicy: Equatable {
    public var maxAvgSpeedMps: Double = 15.0          // ~54 km/h — generous for downhill longboarders
    public var minStraightnessRatio: Double = 0.67    // (reportedLength / haversine) must be >= this
    public var minMovesForWeekBoard: Int = 1          // require at least 1 ride
    public var rejectPremiumBoosts: Bool = true       // ignore any premium-boost flags
    public init() {}
}

public struct LeaderboardSort {
    /// Deterministic, stable sort: distance desc → achievedAt asc → userId asc.
    public static func sort(_ entries: inout [LeaderboardEntry]) {
        entries.sort { a, b in
            if a.distanceMeters != b.distanceMeters { return a.distanceMeters > b.distanceMeters }
            if a.achievedAt != b.achievedAt { return a.achievedAt < b.achievedAt }
            return a.userId < b.userId
        }
    }
}

public struct AntiCheat {
    public static func isValid(_ e: LeaderboardEntry, policy: AntiCheatPolicy, polyDecoder: PolylineDecoding) -> Bool {
        // Quick structural checks
        guard e.movesCount >= policy.minMovesForWeekBoard,
              e.distanceMeters.isFinite, e.distanceMeters > 0 else { return false }

        // Premium boosts must not affect acceptance; we simply ignore e.premiumFlag for ranking.
        if policy.rejectPremiumBoosts, e.premiumFlag == true {
            // Still allowed, just not advantaged; do nothing special here.
        }

        // If geometry not provided, accept but rely on server heuristics.
        guard let s = e.polylineSummary,
              s.reportedMeters > 0,
              s.elapsedSeconds > 0 else { return true }

        // Speed sanity
        let avgSpeed = s.reportedMeters / s.elapsedSeconds
        if avgSpeed > policy.maxAvgSpeedMps { return false }

        // Straightness ratio = reported length / haversine distance of decoded path.
        let coords = polyDecoder.decode(s.encoded)
        if coords.count >= 2 {
            let hav = haversineDistance(coords.first!, coords.last!)
            // If points are collapsed or straight line is zero (identical points), accept (can't judge).
            if hav > 1 {
                let ratio = s.reportedMeters / hav
                if ratio < policy.minStraightnessRatio { return false }
            }
        }
        return true
    }

    private static func haversineDistance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let r = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let h = sin(dLat/2)*sin(dLat/2) + sin(dLon/2)*sin(dLon/2)*cos(lat1)*cos(lat2)
        return 2*r*asin(min(1, sqrt(h)))
    }
}

// MARK: - Service

@MainActor
public final class LeaderboardService: ObservableObject {

    public enum State: Equatable { case idle, loading, ready(BoardScope), error(String) }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var currentScope: BoardScope = .global
    @Published public private(set) var items: [LeaderboardEntry] = []
    @Published public private(set) var nextCursor: String?

    public var pagePublisher: AnyPublisher<[LeaderboardEntry], Never> { $items.eraseToAnyPublisher() }

    // DI
    private let api: LeaderboardRemoteAPI
    private let geocoder: CoarseGeocoding
    private let polyDecoder: PolylineDecoding
    private let policy: AntiCheatPolicy
    private let log = Logger(subsystem: "com.skateroute", category: "LeaderboardService")

    // Local cache to keep pagination deterministic (dedupe by userId within the scope)
    private var seenUserIds = Set<String>()

    public init(api: LeaderboardRemoteAPI,
                geocoder: CoarseGeocoding,
                polyDecoder: PolylineDecoding,
                policy: AntiCheatPolicy = .init()) {
        self.api = api
        self.geocoder = geocoder
        self.polyDecoder = polyDecoder
        self.policy = policy
    }

    // MARK: Public API

    /// Resolve city scope from a coordinate using coarse reverse geocoding.
    public func resolveCityScope(for coordinate: CLLocationCoordinate2D) async -> BoardScope {
        do {
            let key = try await geocoder.cityKey(for: coordinate)
            return .city(key: key)
        } catch {
            log.notice("City key resolution failed, falling back to global: \(error.localizedDescription, privacy: .public)")
            return .global
        }
    }

    /// Load first page for the given scope (resets state).
    public func load(scope: BoardScope, pageSize: Int = 25) async {
        state = .loading
        currentScope = scope
        items.removeAll(keepingCapacity: true)
        nextCursor = nil
        seenUserIds.removeAll(keepingCapacity: true)

        await loadNext(pageSize: pageSize)
    }

    /// Load next page if available; maintains deterministic ordering and idempotent dedupe.
    public func loadNext(pageSize: Int = 25) async {
        switch state {
        case .loading, .ready:
            break
        default:
            state = .loading
        }
        do {
            let (raw, cursor) = try await api.fetch(scope: currentScope, pageSize: pageSize, cursor: nextCursor)

            // Filter invalid/cheaters and dedupe by userId (keep their best score only)
            var accepted: [LeaderboardEntry] = []
            for e in raw {
                guard AntiCheat.isValid(e, policy: policy, polyDecoder: polyDecoder) else { continue }
                // Dedupe: if we already have an entry for userId, prefer the better one (distance desc → achievedAt asc)
                if let existingIdx = items.firstIndex(where: { $0.userId == e.userId }) {
                    let cur = items[existingIdx]
                    if better(e, than: cur) {
                        items[existingIdx] = e
                    }
                } else if !seenUserIds.contains(e.userId) {
                    accepted.append(e)
                    seenUserIds.insert(e.userId)
                }
            }

            // Merge and sort deterministically
            items.append(contentsOf: accepted)
            LeaderboardSort.sort(&items)

            nextCursor = cursor
            state = .ready(currentScope)
        } catch {
            state = .error("Leaderboard load failed")
            log.error("Leaderboard error: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Helpers

    private func better(_ a: LeaderboardEntry, than b: LeaderboardEntry) -> Bool {
        if a.distanceMeters != b.distanceMeters { return a.distanceMeters > b.distanceMeters }
        if a.achievedAt != b.achievedAt { return a.achievedAt < b.achievedAt }
        return a.userId < b.userId
    }
}

// MARK: - Default Coarse Geocoder (privacy-first; locality + countryCode only)

public final class CoarseGeocoder: CoarseGeocoding {
    private let geo = CLGeocoder()
    public init() {}
    public func cityKey(for coordinate: CLLocationCoordinate2D) async throws -> String {
        let placemarks = try await geo.reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), preferredLocale: .autoupdatingCurrent)
        guard let p = placemarks.first else { throw NSError(domain: "Geocode", code: 1) }
        let city = (p.locality ?? p.subAdministrativeArea ?? p.administrativeArea ?? "unknown")
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let country = (p.isoCountryCode ?? "xx").lowercased()
        return "\(country)-\(city)"
    }
}

// MARK: - Default Polyline Decoder (Google-style)

// Lightweight decoder with 1e5 precision.
public final class GooglePolylineDecoder: PolylineDecoding {
    public init() {}
    public func decode(_ encoded: String) -> [CLLocationCoordinate2D] {
        let data = Array(encoded.utf8)
        var idx = 0
        var lat = 0
        var lon = 0
        var coords: [CLLocationCoordinate2D] = []
        while idx < data.count {
            let dLat = decodeVar(&idx, data)
            let dLon = decodeVar(&idx, data)
            lat += dLat
            lon += dLon
            coords.append(CLLocationCoordinate2D(latitude: Double(lat) / 1e5, longitude: Double(lon) / 1e5))
        }
        return coords
    }
    private func decodeVar(_ idx: inout Int, _ bytes: [UInt8]) -> Int {
        var result = 0
        var shift = 0
        var b: Int
        repeat {
            b = Int(bytes[idx]) - 63
            idx += 1
            result |= (b & 0x1F) << shift
            shift += 5
        } while b >= 0x20 && idx < bytes.count
        let delta = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1)
        return delta
    }
}

// MARK: - DEBUG Fakes (for tests)

#if DEBUG
public final class LeaderboardAPIFake: LeaderboardRemoteAPI {
    public var pages: [(items: [LeaderboardEntry], next: String?)] = []
    private var cursorIndex: [String?: Int] = [:]
    public init() {}
    public func fetch(scope: BoardScope, pageSize: Int, cursor: String?) async throws -> (items: [LeaderboardEntry], nextCursor: String?) {
        let i = cursorIndex[cursor] ?? 0
        guard i < pages.count else { return ([], nil) }
        cursorIndex[cursor] = i + 1
        return (pages[i].items, pages[i].next)
    }
}

public final class CoarseGeocoderFake: CoarseGeocoding {
    private let key: String
    public init(key: String = "xx-testville") { self.key = key }
    public func cityKey(for coordinate: CLLocationCoordinate2D) async throws -> String { key }
}

public final class PolylineDecoderFake: PolylineDecoding {
    private let coords: [CLLocationCoordinate2D]
    public init(coords: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 49.28, longitude: -123.12),
        CLLocationCoordinate2D(latitude: 49.30, longitude: -123.10)
    ]) { self.coords = coords }
    public func decode(_ encoded: String) -> [CLLocationCoordinate2D] { coords }
}
#endif

// MARK: - Tests you should implement (summary)
//
// • Pagination determinism:
//   - Seed LeaderboardAPIFake with multiple pages containing overlapping users; call load(scope: .global) then loadNext() twice.
//   - Assert `items` are unique by userId and sorted distance desc → achievedAt asc → userId asc; cursor flows as expected.
//
// • Tie-breaks stable:
//   - Two entries with equal distance: earlier `achievedAt` ranks higher; if equal, lexicographically smaller `userId` wins.
//   - Verify idempotency when a later page brings a better score for an already-present user — list updates and remains sorted.
//
// • Cheater rejection:
//   - Entry with avg speed > maxAvgSpeedMps → filtered out.
//   - Entry with straightness ratio < minStraightnessRatio (e.g., 100 km reported over 10 km haversine) → filtered out.
//   - Entry with premiumFlag == true must *not* receive any special ranking — it’s treated the same as others.
//
// • City/global routing:
//   - CoarseGeocoderFake returns "ca-vancouver"; call resolveCityScope() and load(scope: .city(key: ...)) — ensure service uses the key, not the raw coordinate.
//   - If geocoder throws, fallback to .global.
//
// Integration:
//   - Wire into AppDI with your concrete API adapter, `CoarseGeocoder()`, and `GooglePolylineDecoder()`.
//   - Features/Challenges/LeaderboardView subscribes to `pagePublisher`, calls `load(scope:)` at appear, and `loadNext()` on scroll.
//   - Keep payloads tiny: server should include low-res polylines only for suspicious entries; otherwise omit `polylineSummary` to save bytes.
//   - Respect accessibility: ensure row VO labels read rank, name, distance, and timestamp of achievement.


