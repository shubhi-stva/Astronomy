//
//  CelestialObject.swift
//  Astronomy
//
//  Unified model for anything that can be selected/searched in the sky:
//  stars, the Sun, the Moon, and planets.
//

import Foundation

enum CelestialObjectKind: String, Codable {
    case star, sun, moon, planet
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
}
