//
//  CelestialObject.swift
//  Astronomy
//
//  Unified model for anything that can be selected/searched in the sky:
//  stars, the Sun, the Moon, and planets.
//

import Foundation

enum CelestialObjectKind: String, Codable {
    case star, sun, moon, planet, deepSky
    /// Artificial satellites. Unlike everything else in this enum these are
    /// *near*: their apparent position depends on where the observer stands,
    /// not just when they look, so they never travel the RA/Dec path the other
    /// kinds do. See `TopocentricTransform`.
    case satellite
}

struct CelestialObject: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: CelestialObjectKind
    let equatorial: EquatorialCoordinate
    let magnitude: Double

    /// B-V color index, only meaningful for stars. Nil for solar-system bodies.
    var colorIndex: Double?

    /// Distance from the observer, in kilometres. Populated for solar-system
    /// bodies by `EphemerisService` so the renderer can size the disk from the
    /// true angular diameter `2 * atan(radius / distance)` instead of a fixed
    /// nominal value. Nil for stars (their disks are unresolvable).
    var distanceKilometres: Double?

    /// Illuminated fraction of the disk, 0 (new) ... 1 (full). Populated for
    /// the Moon and the planets; nil for the Sun and stars.
    var illuminatedFraction: Double?

    /// Morphological class, populated only for `.deepSky` objects.
    var deepSkyType: DeepSkyType?

    /// Catalogue designation ("M31", "NGC 7000") where the display name is a
    /// common name. Used by search so both spellings match.
    var catalogDesignation: String?

    /// True angular extent in arcminutes, for extended (deep-sky) objects.
    /// The renderer sizes the sprite from these instead of a magnitude-driven
    /// marker, which is what makes M31 read as a 3-degree ellipse.
    var majorAxisArcmin: Double?
    var minorAxisArcmin: Double?
    /// Major-axis orientation in degrees east of north.
    var positionAngleDegrees: Double?

    /// Extra facts carried only by `.satellite` objects, so the info panel can
    /// say something genuinely useful about one.
    var satelliteDetails: SatelliteDetails?
}

/// Everything the info panel shows for a selected satellite that no other kind
/// of object has.
struct SatelliteDetails: Hashable {
    let catalogNumber: Int
    /// Index into the tracker's descriptor array. Carried so that refreshing a
    /// selected satellite every frame is a binary search over the snapshot
    /// rather than a linear scan of sixteen thousand samples.
    let descriptorIndex: Int
    let regime: OrbitalRegime
    /// Height above the WGS-84 ellipsoid, in kilometres.
    let altitudeAboveGroundKm: Double
    /// Observer-to-satellite distance, in kilometres.
    let rangeKilometres: Double
    let horizontal: HorizontalCoordinate
    let illumination: TopocentricTransform.Illumination
    /// Age of the element set at the displayed time, in days.
    let elementSetAgeDays: Double
    let internationalDesignator: String
}
