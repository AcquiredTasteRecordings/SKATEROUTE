// Services/OfflineRouteStore.swift
import Foundation
import CoreLocation
import MapKit

/// Persists scored route options to disk so that the planner can be used offline.
public final class OfflineRouteStore {
    public struct RequestKey: Hashable {
        public let source: CLLocationCoordinate2D
        public let destination: CLLocationCoordinate2D
        public let mode: RideMode

        public init(source: CLLocationCoordinate2D, destination: CLLocationCoordinate2D, mode: RideMode) {
            self.source = source
            self.destination = destination
            self.mode = mode
        }

        var cacheKey: String {
            let src = String(format: "%.5f,%.5f", source.latitude, source.longitude)
            let dst = String(format: "%.5f,%.5f", destination.latitude, destination.longitude)
            return "route-\(src)-\(dst)-\(mode.rawValue)"
        }
    }

    public struct Snapshot: Codable {
        public struct Coordinate: Codable {
            public let latitude: Double
            public let longitude: Double

            public init(latitude: Double, longitude: Double) {
                self.latitude = latitude
                self.longitude = longitude
            }

            public init(coordinate: CLLocationCoordinate2D) {
                self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
            }

            public var clCoordinate: CLLocationCoordinate2D {
                CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            }
        }

        public let id: UUID
        public let candidateID: String
        public let title: String
        public let detail: String
        public let score: Double
        public let scoreLabel: String
        public let roughnessEstimate: Double
        public let distance: Double
        public let travelTime: Double
        public let metadata: RouteService.RouteCandidateMetadata
        public let polyline: [Coordinate]
        public let cachedAt: Date

        public init(id: UUID,
                    candidateID: String,
                    title: String,
                    detail: String,
                    score: Double,
                    scoreLabel: String,
                    roughnessEstimate: Double,
                    distance: Double,
                    travelTime: Double,
                    metadata: RouteService.RouteCandidateMetadata,
                    polyline: [Coordinate],
                    cachedAt: Date = Date()) {
            self.id = id
            self.candidateID = candidateID
            self.title = title
            self.detail = detail
            self.score = score
            self.scoreLabel = scoreLabel
            self.roughnessEstimate = roughnessEstimate
            self.distance = distance
            self.travelTime = travelTime
            self.metadata = metadata
            self.polyline = polyline
            self.cachedAt = cachedAt
        }

        public func makePolyline() -> MKPolyline {
            let coords = polyline.map { $0.clCoordinate }
            return MKPolyline(coordinates: coords, count: coords.count)
        }
    }

    private let cache = CacheManager.shared
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init() {
        encoder.outputFormatting = [.prettyPrinted]
    }

    public func store(_ snapshots: [Snapshot], for key: RequestKey) {
        guard let data = try? encoder.encode(snapshots) else { return }
        try? cache.store(data, key: key.cacheKey)
    }

    public func load(for key: RequestKey) -> [Snapshot]? {
        guard let data = cache.data(for: key.cacheKey) else { return nil }
        return try? decoder.decode([Snapshot].self, from: data)
    }
}
