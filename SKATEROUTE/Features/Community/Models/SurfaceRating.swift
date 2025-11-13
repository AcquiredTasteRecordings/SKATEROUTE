// Features/Community/Models/SurfaceRating.swift
import Foundation
import SwiftData
import CoreLocation

/// Discrete surface quality used across the app.
/// Stored as Int in the model for migration and query simplicity.
public enum SurfaceValue: Int, CaseIterable, Codable, Sendable {
    case crusty = 0    // rough, cracked
    case okay   = 1    // acceptable / mixed
    case butter = 2    // smooth, prime

    public var description: String {
        switch self {
        case .butter: return "Butter"
        case .okay:   return "Okay"
        case .crusty: return "Crusty"
        }
    }

    public var emoji: String {
        switch self {
        case .butter: return "🧈"
        case .okay:   return "👌"
        case .crusty: return "🪨"
        }
    }

    /// Clamp any incoming Int (0…2). Defaults to `.okay` when out of range.
    public static func fromClamped(_ raw: Int) -> SurfaceValue {
        switch raw {
        case 2: return .butter
        case 1: return .okay
        case 0: return .crusty
        default: return .okay
        }
    }
}

/// Represents a rating for a surface at a specific geographic location.
/// SwiftData model; keep value-semantic derived helpers @Transient.
@Model
public final class SurfaceRating {
    // MARK: Persisted

    /// Stable unique identifier.
    @Attribute(.unique) public var id: UUID

    /// Latitude/Longitude of the rated surface (WGS84 degrees).
    public var latitude: Double
    public var longitude: Double

    /// Numeric rating value: 2 = butter, 1 = okay, 0 = crusty.
    /// Stored as Int for compactness and easy querying; prefer `valueEnum` in code.
    public var value: Int

    /// Creation and last update timestamps.
    public var createdAt: Date
    public var updatedAt: Date

    // MARK: Derived (non-persisted)

    /// Convenience wrapper around `value`.
    @Transient public var valueEnum: SurfaceValue {
        get { SurfaceValue.fromClamped(value) }
        set { value = newValue.rawValue }
    }

    /// Coordinate composed from latitude/longitude.
    @Transient public var coordinate: CLLocationCoordinate2D {
        .init(latitude: latitude, longitude: longitude)
    }

    /// Human-friendly summary of value.
    @Transient public var valueDescription: String { valueEnum.description }

    /// Emoji hint for quick UI affordances.
    @Transient public var emoji: String { valueEnum.emoji }

    /// Quantized tile key for simple local grouping/merge (≈ 11 m @ 1e-4°).
    /// Adjust precision if you want larger/smaller bins.
    @Transient public var tileKey: String {
        Self.quantizedKey(latitude: latitude, longitude: longitude, precision: 4)
    }

    // MARK: Init

    /// Designated initializer.
    /// - Parameters:
    ///   - id: Optional UUID; defaults to a new UUID.
    ///   - latitude/longitude: Degrees.
    ///   - value: 0…2; out-of-range inputs are clamped.
    ///   - createdAt: Defaults to now. `updatedAt` is set to same value initially.
    public init(
        id: UUID = UUID(),
        latitude: Double,
        longitude: Double,
        value: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.value = SurfaceValue.fromClamped(value).rawValue
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// Convenience init from a `CLLocationCoordinate2D`.
    public convenience init(
        coordinate: CLLocationCoordinate2D,
        value: SurfaceValue,
        createdAt: Date = Date()
    ) {
        self.init(latitude: coordinate.latitude,
                  longitude: coordinate.longitude,
                  value: value.rawValue,
                  createdAt: createdAt)
    }

    // MARK: Mutations

    /// Update the rating value and touch the `updatedAt` timestamp.
    @discardableResult
    public func updateValue(_ newValue: SurfaceValue, at date: Date = Date()) -> Self {
        self.value = newValue.rawValue
        self.updatedAt = date
        return self
    }

    /// Move the rating to a new coordinate and touch the `updatedAt` timestamp.
    @discardableResult
    public func move(to coordinate: CLLocationCoordinate2D, at date: Date = Date()) -> Self {
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.updatedAt = date
        return self
    }

    // MARK: Utilities

    /// Quantized key for bucketing nearby points without expensive geofencing.
    public static func quantizedKey(latitude: Double, longitude: Double, precision: Int) -> String {
        let p = pow(10.0, Double(precision))
        let lat = (latitude * p).rounded() / p
        let lon = (longitude * p).rounded() / p
        return "\(lat),\(lon)"
    }

    /// Distance (meters) to another coordinate (haversine).
    public func distanceMeters(to coord: CLLocationCoordinate2D) -> CLLocationDistance {
        let a = MKMapPoint(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        let b = MKMapPoint(coord)
        return MKMetersBetweenMapPoints(a, b)
    }

    // MARK: Samples

    /// Sample value for previews/tests.
    public static func sample(_ value: SurfaceValue = .butter) -> SurfaceRating {
        SurfaceRating(latitude: 37.7749, longitude: -122.4194, value: value.rawValue)
    }
}

// MARK: - Codable bridge
// Handy for export/import without leaking SwiftData internals.
extension SurfaceRating: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, latitude, longitude, value, createdAt, updatedAt
    }

    public convenience init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(UUID.self, forKey: .id)
        let lat = try c.decode(Double.self, forKey: .latitude)
        let lon = try c.decode(Double.self, forKey: .longitude)
        let value = try c.decode(Int.self, forKey: .value)
        let created = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        let updated = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? created
        self.init(id: id, latitude: lat, longitude: lon, value: value, createdAt: created)
        self.updatedAt = updated
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(latitude, forKey: .latitude)
        try c.encode(longitude, forKey: .longitude)
        try c.encode(value, forKey: .value)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}


