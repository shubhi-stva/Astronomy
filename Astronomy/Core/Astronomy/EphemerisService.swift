//
//  EphemerisService.swift
//  Astronomy
//
//  Facade over the individual Sun/Moon/planet position calculators,
//  producing a unified list of `CelestialObject` values for a given time.
//  Pure calculation layer — no rendering or SwiftUI dependencies.
//

import Foundation

enum EphemerisService {

    /// Computes the current positions of the Sun, Moon, and all seven other
    /// major planets for the given Julian Day.
    static func solarSystemObjects(julianDay jd: Double) -> [CelestialObject] {
        var objects: [CelestialObject] = []

        let sunEq = SunPosition.equatorialCoordinate(julianDay: jd)
        objects.append(CelestialObject(
            id: "sun",
            name: "Sun",
            kind: .sun,
            equatorial: sunEq,
            magnitude: -26.7
        ))

        let moonEq = MoonPosition.equatorialCoordinate(julianDay: jd)
        objects.append(CelestialObject(
            id: "moon",
            name: "Moon",
            kind: .moon,
            equatorial: moonEq,
            magnitude: -12.7
        ))

        for planet in Planet.allCases {
            let eq = PlanetPosition.equatorialCoordinate(planet: planet, julianDay: jd)
            objects.append(CelestialObject(
                id: planet.rawValue,
                name: planet.displayName,
                kind: .planet,
                equatorial: eq,
                magnitude: approximateMagnitude(for: planet)
            ))
        }

        return objects
    }

    /// Rough, static apparent-magnitude estimate per planet (ignores phase
    /// angle / distance variation) — sufficient for marker sizing in the MVP.
    private static func approximateMagnitude(for planet: Planet) -> Double {
        switch planet {
        case .mercury: return -0.4
        case .venus: return -4.2
        case .mars: return -0.5
        case .jupiter: return -2.2
        case .saturn: return 0.5
        case .uranus: return 5.7
        case .neptune: return 7.8
        }
    }
}
