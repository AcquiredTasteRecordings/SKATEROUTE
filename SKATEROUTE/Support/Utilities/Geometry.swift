// Core/Geometry.swift
// Robust, battery-light geometry helpers for routing and HUDs.
// Uses MKMapPoint space for stable, fast math. Provides snapping/progress/distance
// that align with RerouteController and overlay renderers.

import Foundation
import MapKit
import CoreLocation

public enum Geometry {
    // MARK: - Snap / Distance

    /// Returns the nearest point on `polyline` to `coord` along with metadata.
    /// - Returns: snapped coordinate, segment index (leading vertex), and param t∈[0,1] along that segment.
    public static func nearestPoint(
        to coord: CLLocationCoordinate2D,
        on polyline: MKPolyline,
        maxVertexScan: Int = 5_000
    ) -> (coordinate: CLLocationCoordinate2D, segmentIndex: Int, t: Double)? {
        let pts = polyline.mkMapPointsCapped(maxVertexScan)
        guard pts.count > 1 else { return nil }

        let p = MKMapPoint(coord)
        var bestDist = CLLocationDistance.greatestFiniteMagnitude
        var bestIdx = 0
        var bestT = 0.0
        var bestPoint = MKMapPoint(x: 0, y: 0)

        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let (d, t, proj) = distanceAndProjection(p, a, b)
            if d < bestDist {
                bestDist = d
                bestIdx = i
                bestT = t
                bestPoint = proj
            }
        }

        return (bestPoint.coordinate, bestIdx, bestT)
    }

    /// Snap `coord` to the nearest point on `polyline`.
    public static func snap(_ coord: CLLocationCoordinate2D, to polyline: MKPolyline) -> CLLocationCoordinate2D {
        nearestPoint(to: coord, on: polyline)?.coordinate ?? coord
    }

    /// Fast distance (meters) from `coord` to `polyline`.
    public static func distanceMeters(_ coord: CLLocationCoordinate2D, to polyline: MKPolyline) -> CLLocationDistance {
        let pts = polyline.mkMapPointsCapped()
        guard pts.count > 1 else { return .greatestFiniteMagnitude }
        let p = MKMapPoint(coord)
        var best = CLLocationDistance.greatestFiniteMagnitude
        for i in 0..<(pts.count - 1) {
            let (d, _, _) = distanceAndProjection(p, pts[i], pts[i+1])
            if d < best { best = d }
        }
        return best
    }

    // MARK: - Progress / Remaining Distance

    /// Computes route progress and remaining distance from a rider `location` along `polyline`.
    /// - Returns: (progress 0…1, remaining meters). Returns nil if polyline degenerate.
    public static func progress(
        along polyline: MKPolyline,
        from location: CLLocationCoordinate2D
    ) -> (progress: Double, remaining: CLLocationDistance)? {
        let pts = polyline.mkMapPointsCapped()
        guard pts.count > 1 else { return nil }

        // Total length (cached by call-site if needed)
        let total = totalLength(pts)

        // Find nearest segment and projection
        let p = MKMapPoint(location)
        var bestIdx = 0
        var bestT = 0.0
        var bestDist = CLLocationDistance.greatestFiniteMagnitude
        var bestProj = MKMapPoint(x: 0, y: 0)
        for i in 0..<(pts.count - 1) {
            let (d, t, proj) = distanceAndProjection(p, pts[i], pts[i+1])
            if d < bestDist {
                bestDist = d
                bestIdx = i
                bestT = t
                bestProj = proj
            }
        }

        // Distance from start to the projection
        var traversed: CLLocationDistance = 0
        if bestIdx > 0 {
            traversed = length(pts[0...bestIdx])
        }
        traversed += bestProj.distance(to: pts[bestIdx])

        let remaining = max(0, total - traversed)
        let progress = total > 0 ? max(0, min(1, traversed / total)) : 0
        return (progress, remaining)
    }

    /// Remaining meters from `location` to the end of `polyline`.
    public static func remainingDistance(from location: CLLocationCoordinate2D, on polyline: MKPolyline) -> CLLocationDistance {
        progress(along: polyline, from: location)?.remaining ?? 0
    }

    // MARK: - Private math

    /// Distance from P to segment AB, returning (meters, t, projection).
    private static func distanceAndProjection(_ p: MKMapPoint, _ a: MKMapPoint, _ b: MKMapPoint) -> (CLLocationDistance, Double, MKMapPoint) {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len2 = dx*dx + dy*dy
        if len2 == 0 {
            let d = p.distance(to: a)
            return (d, 0.0, a)
        }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = max(0, min(1, t))
        let proj = MKMapPoint(x: a.x + t * dx, y: a.y + t * dy)
        let d = p.distance(to: proj)
        return (d, t, proj)
    }

    private static func length(_ pts: ArraySlice<MKMapPoint>) -> CLLocationDistance {
        guard pts.count > 1 else { return 0 }
        var sum: CLLocationDistance = 0
        var prev = pts.first!
        var i = pts.startIndex + 1
        while i < pts.endIndex {
            let cur = pts[i]
            sum += prev.distance(to: cur)
            prev = cur
            i = pts.index(after: i)
        }
        return sum
    }

    private static func totalLength(_ pts: [MKMapPoint]) -> CLLocationDistance {
        length(pts[0..<pts.count])
    }
}

// MARK: - MKPolyline utilities

public extension MKPolyline {
    /// Extracts coordinates (CLLocationCoordinate2D array). Allocate once where possible.
    func coordinates() -> [CLLocationCoordinate2D] {
        let n = pointCount
        guard n > 0 else { return [] }
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: n)
        getCoordinates(&coords, range: NSRange(location: 0, length: n))
        return coords
    }

    /// Nearest *vertex index* to a CLLocation (kept for compatibility).
    /// Prefer `Geometry.nearestPoint` for projection onto segments.
    func nearestIndex(to location: CLLocation) -> Int {
        let n = pointCount
        guard n > 0 else { return 0 }
        var pts = [CLLocationCoordinate2D](repeating: .init(), count: n)
        getCoordinates(&pts, range: NSRange(location: 0, length: n))
        var best = 0
        var bestDist = CLLocationDistance.greatestFiniteMagnitude
        for (i, c) in pts.enumerated() {
            let d = location.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }

    /// Remaining distance (meters) from a CLLocation along the polyline.
    /// Uses projection to the nearest segment for accuracy.
    func remainingDistance(from location: CLLocation) -> CLLocationDistance {
        Geometry.remainingDistance(from: location.coordinate, on: self)
    }

    /// Total polyline length (meters).
    func totalLengthMeters(maxVertexScan: Int = 5_000) -> CLLocationDistance {
        let pts = mkMapPointsCapped(maxVertexScan)
        guard pts.count > 1 else { return 0 }
        var sum: CLLocationDistance = 0
        for i in 0..<(pts.count - 1) {
            sum += pts[i].distance(to: pts[i+1])
        }
        return sum
    }
}

// MARK: - MKPolyline (MapPoint extraction with defensive cap)

private extension MKPolyline {
    /// Extract MKMapPoints and defensively cap very long polylines for performance.
    /// Preserves end points; uniform subsampling.
    func mkMapPointsCapped(_ maxVertices: Int = 5_000) -> [MKMapPoint] {
        let n = pointCount
        guard n > 0 else { return [] }
        var pts = [MKMapPoint](repeating: .init(), count: n)
        getPoints(UnsafeMutablePointer(mutating: &pts), range: NSRange(location: 0, length: n))

        guard n > maxVertices, maxVertices > 2 else { return pts }

        let step = Double(n - 1) / Double(maxVertices - 1)
        var out: [MKMapPoint] = []
        out.reserveCapacity(maxVertices)
        var i = 0.0
        while Int(i.rounded()) < n && out.count < maxVertices {
            out.append(pts[Int(i.rounded())])
            i += step
        }
        if out.last != pts.last { out.append(pts.last!) }
        return out
    }

    func getPoints(_ buffer: UnsafeMutablePointer<MKMapPoint>, range: NSRange) {
        self.getPoints(buffer, range: range)
    }
}
