import Foundation
import MapKit
import CoreLocation

public enum Geometry {
    public static func snap(_ location: CLLocationCoordinate2D, to polyline: MKPolyline) -> CLLocationCoordinate2D {
        let pts = polyline.coordinates()
        guard let first = pts.first else { return location }
        var best = first
        var bestDist = distanceSquared(location, first)
        for c in pts.dropFirst() {
            let d = distanceSquared(location, c)
            if d < bestDist { bestDist = d; best = c }
        }
        return best
    }

    private static func distanceSquared(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dx = a.latitude - b.latitude
        let dy = a.longitude - b.longitude
        return dx*dx + dy*dy
    }
}

public extension MKPolyline {
    func coordinates() -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }

    func remainingDistance(from location: CLLocation) -> CLLocationDistance {
        let coords = coordinates()
        guard coords.count >= 2 else { return 0 }
        var total: CLLocationDistance = 0
        var i = nearestIndex(to: location)
        while i < coords.count - 1 {
            let a = coords[i], b = coords[i+1]
            total += CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            i += 1
        }
        return max(0, total)
    }

    func nearestIndex(to location: CLLocation) -> Int {
        let coords = coordinates()
        guard !coords.isEmpty else { return 0 }
        var bestIndex = 0
        var bestDist: CLLocationDistance = .greatestFiniteMagnitude  // <-- fix
        for (i, c) in coords.enumerated() {
            let d = location.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            if d < bestDist { bestDist = d; bestIndex = i }
        }
        return bestIndex
    }
}
