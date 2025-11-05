// Core/SmoothOverlayRenderer.swift
import CoreLocation

public enum AppRouter: Equatable {
    /// Represents the home route.
    case home
    /// Represents a map route with source and destination coordinates and a ride mode.
    case map(source: CLLocationCoordinate2D,
             destination: CLLocationCoordinate2D,
             mode: RideMode = .smoothest)

    /// Checks equality between two AppRouter instances.
    /// - Parameters:
    ///   - lhs: The left-hand side AppRouter instance.
    ///   - rhs: The right-hand side AppRouter instance.
    /// - Returns: True if both instances are equal, false otherwise.
    public static func == (lhs: AppRouter, rhs: AppRouter) -> Bool {
        switch (lhs, rhs) {
        case (.home, .home):
            return true
        case let (.map(s1, d1, m1), .map(s2, d2, m2)):
            return s1.isClose(to: s2) && d1.isClose(to: d2) && m1 == m2
        default:
            return false
        }
    }
}

fileprivate extension CLLocationCoordinate2D {
    /// Determines if two coordinates are close to each other within a specified epsilon.
    /// - Parameters:
    ///   - other: The other coordinate to compare.
    ///   - eps: The epsilon tolerance for comparison.
    /// - Returns: True if coordinates are within epsilon, false otherwise.
    func isClose(to other: CLLocationCoordinate2D, eps: Double = 1e-6) -> Bool {
        abs(latitude - other.latitude) < eps && abs(longitude - other.longitude) < eps
    }
}
