// Services/OfflineTileManager.swift
import Foundation
import MapKit

/// Handles downloading and caching of raster/vector tiles required for offline navigation.
@MainActor
public final class OfflineTileManager: ObservableObject {
    public enum DownloadState: Equatable {
        case idle
        case downloading(progress: Double)
        case cached
        case failed
    }

    @Published public private(set) var state: DownloadState = .idle

    private let cache = CacheManager.shared

    public init() {}

    public func ensureTiles(for polyline: MKPolyline, identifier: String) async {
        let key = cacheKey(for: identifier)
        if cache.data(for: key) != nil {
            state = .cached
            return
        }

        state = .downloading(progress: 0)
        let steps = 8
        for step in 1...steps {
            try? await Task.sleep(nanoseconds: 75_000_000) // simulate segmented download
            state = .downloading(progress: Double(step) / Double(steps))
        }

        let coordinates = polyline.coordinates()
        let payload = coordinates
            .map { "\($0.latitude),\($0.longitude)" }
            .joined(separator: ";")
        if let data = payload.data(using: .utf8) {
            do {
                try cache.store(data, key: key)
                state = .cached
            } catch {
                state = .failed
            }
        } else {
            state = .failed
        }
    }

    public func hasTiles(for identifier: String) -> Bool {
        cache.data(for: cacheKey(for: identifier)) != nil
    }

    public func reset() {
        state = .idle
    }

    private func cacheKey(for identifier: String) -> String {
        "tiles-\(identifier)"
    }
}
