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
}
