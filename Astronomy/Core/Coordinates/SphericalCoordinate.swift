//
//  SphericalCoordinate.swift
//  Astronomy
//
//  Basic spherical coordinate value types used across the calculation and
//  rendering layers. Pure data — no SwiftUI/Metal imports.
//

import Foundation

/// Equatorial coordinates: Right Ascension / Declination, the fixed
/// "catalog" position of an object independent of observer and time.
struct EquatorialCoordinate: Hashable, Codable {
    /// Right Ascension, in degrees (0...360).
    var rightAscensionDegrees: Double
    /// Declination, in degrees (-90...90).
    var declinationDegrees: Double

    var rightAscensionHours: Double { rightAscensionDegrees / 15.0 }
}

/// Horizontal coordinates: Altitude / Azimuth, observer- and time-dependent.
struct HorizontalCoordinate: Hashable {
    /// Altitude above the horizon, in degrees (-90...90).
    var altitudeDegrees: Double
    /// Azimuth measured clockwise from true north, in degrees (0...360).
    var azimuthDegrees: Double
}

/// Observer's geographic location.
struct GeographicLocation: Hashable, Codable {
    var latitudeDegrees: Double
    var longitudeDegrees: Double

    /// Neutral starting point used only until a real location is known, so the
    /// sky can render on the very first frame. Deliberately *not* a real city:
    /// presenting a specific place the user isn't in would be misleading. The
    /// UI labels this state explicitly (see `LocationService.Source.fallback`).
    static let fallbackObserver = GeographicLocation(latitudeDegrees: 0, longitudeDegrees: 0)
}

enum Angle {
    static func degreesToRadians(_ degrees: Double) -> Double { degrees * .pi / 180.0 }
    static func radiansToDegrees(_ radians: Double) -> Double { radians * 180.0 / .pi }

    /// Normalizes a degree value into [0, 360).
    static func normalizeDegrees(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360.0)
        if d < 0 { d += 360.0 }
        return d
    }
}
