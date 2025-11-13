// Core/Navigation/SurfaceType.swift
// Canonical enumeration of rideable surfaces used by navigation services.

import Foundation

/// Canonical enumeration of surfaces relevant to SkateRoute navigation.
///
/// Keep the cases coarse-grained and stable; they mirror the categorization we
/// get from third-party map data as well as community-sourced annotations.
/// This type lives in Core so that both services and features can depend on a
/// single surface vocabulary without creating layering cycles.
public enum SurfaceType: String, CaseIterable, Codable, Sendable {
    case unknown
    case asphalt
    case concrete
    case brick
    case boardwalk
    case gravel
    case dirt
    case grass
    case metal
    case tile

    /// Whether the surface is generally considered smooth for small wheels.
    public var isSmoothPreferred: Bool {
        switch self {
        case .unknown, .gravel, .dirt, .grass: return false
        case .asphalt, .concrete, .brick, .boardwalk, .metal, .tile: return true
        }
    }
}
