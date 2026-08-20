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

    // MARK: - Validity window

    /// The span over which the Sun/Moon/planet models are honest, as calendar
    /// years.
    ///
    /// The planetary positions come from JPL's Keplerian element set (Standish,
    /// "Keplerian Elements for Approximate Positions of the Major Planets"),
    /// which is published with two element tables: one fitted for **1800 AD to
    /// 2050 AD**, and a lower-accuracy one for 3000 BC to 3000 AD. This app
    /// carries the first, so 1800-2050 is where its few-arcminute accuracy
    /// claim actually holds. The Moon uses a truncated form of Meeus Ch. 47,
    /// whose neglected terms grow slowly but whose accuracy is likewise quoted
    /// for the modern era.
    ///
    /// **The decision: the time-machine picker is clamped to this window, and
    /// the step buttons stop at its edges.** Outside it the code would still
    /// produce numbers, and they would still look like a sky — degrees wrong,
    /// with nothing on screen to say so. Refusing to leave the window is the
    /// only option that cannot mislead, and 1800-2050 is a wider span than any
    /// "what does my sky look like in two months" question needs.
    ///
    /// Precession itself (`Precession`) is good far outside this range; it is
    /// the solar-system side that sets the limit.
    static let validYearRange = 1800...2050

    /// The validity window as dates, in UTC.
    static let validDateRange: ClosedRange<Date> = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.date(from: DateComponents(year: validYearRange.lowerBound, month: 1, day: 1))!
        let end = calendar.date(
            from: DateComponents(year: validYearRange.upperBound, month: 12, day: 31, hour: 23, minute: 59)
        )!
        return start...end
    }()

    /// Clamps an instant into the window the models are valid over.
    static func clamped(_ date: Date) -> Date {
        min(max(date, validDateRange.lowerBound), validDateRange.upperBound)
    }

    /// Computes the current positions of the Sun, Moon, the seven other major
    /// planets and Pluto for the given Julian Day.
    static func solarSystemObjects(julianDay jd: Double) -> [CelestialObject] {
        var objects: [CelestialObject] = []

        let sunEq = SunPosition.equatorialCoordinate(julianDay: jd)
        let sunDistanceKm = SunPosition.radiusVectorAU(julianDay: jd)
            * AstronomicalConstants.astronomicalUnitKilometres
        objects.append(CelestialObject(
            id: "sun",
            name: "Sun",
            kind: .sun,
            equatorial: sunEq,
            magnitude: -26.7,
            distanceKilometres: sunDistanceKm
        ))

        let moonEq = MoonPosition.equatorialCoordinate(julianDay: jd)
        objects.append(CelestialObject(
            id: "moon",
            name: "Moon",
            kind: .moon,
            equatorial: moonEq,
            magnitude: -12.7,
            distanceKilometres: MoonPosition.distanceKilometres(julianDay: jd),
            illuminatedFraction: MoonPhase.illuminatedFraction(sun: sunEq, moon: moonEq)
        ))

        for planet in Planet.allCases {
            let state = PlanetPosition.state(planet: planet, julianDay: jd)
            objects.append(CelestialObject(
                id: planet.rawValue,
                name: planet.displayName,
                kind: planet.isDwarfPlanet ? .dwarfPlanet : .planet,
                equatorial: state.equatorial,
                magnitude: approximateMagnitude(for: planet),
                distanceKilometres: state.geocentricDistanceAU
                    * AstronomicalConstants.astronomicalUnitKilometres,
                illuminatedFraction: state.illuminatedFraction
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
        // Pluto ranges roughly 13.7-16.3 over its orbit; ~14.4 is where it
        // sits in the 2020s. Far below any naked-eye limit, which is exactly
        // why it is classified `.dwarfPlanet` and left subject to the cutoff.
        case .pluto: return 14.4
        }
    }
}
