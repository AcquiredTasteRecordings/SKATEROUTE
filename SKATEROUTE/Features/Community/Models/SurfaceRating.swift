// Features/Community/Models/SurfaceRating.swift
import Foundation
import SwiftData

/// Represents a rating of a surface at a specific geographic location.
@Model
public final class SurfaceRating {
    /// Unique identifier for the surface rating.
    @Attribute(.unique) public var id: UUID
    /// Latitude coordinate of the surface location.
    public var latitude: Double
    /// Longitude coordinate of the surface location.
    public var longitude: Double
    /// Numeric rating value: 2 = butter, 1 = okay, 0 = crusty.
    public var value: Int
    /// Timestamp when the rating was created.
    public var createdAt: Date

    /// Initializes a new SurfaceRating instance.
    /// - Parameters:
    ///   - id: Unique identifier, defaults to a new UUID.
    ///   - latitude: Latitude coordinate.
    ///   - longitude: Longitude coordinate.
    ///   - value: Numeric surface rating value.
    ///   - createdAt: Creation date, defaults to current date.
    public init(id: UUID = .init(), latitude: Double, longitude: Double, value: Int, createdAt: Date = .init()) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.value = value
        self.createdAt = createdAt
    }

    /// Human-readable string representation of the surface rating value.
    public var valueDescription: String {
        switch value {
        case 2: return "Butter"
        case 1: return "Okay"
        case 0: return "Crusty"
        default: return "Unknown"
        }
    }

    /// Creates a sample SurfaceRating instance for previews or testing.
    /// - Returns: A sample SurfaceRating with preset values.
    public static func sample() -> SurfaceRating {
        SurfaceRating(latitude: 37.7749, longitude: -122.4194, value: 2)
    }
}
