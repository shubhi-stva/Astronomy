//
//  EphemerisService.swift
//  Astronomy
//
//  Facade over the individual Sun/Moon/planet position calculators,
//  producing a unified list of `CelestialObject` values for a given time.
//  Pure calculation layer — no rendering or SwiftUI dependencies.
//

import Foundation
import simd

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

    /// Computes the apparent positions of the Sun, Moon, the seven other major
    /// planets and Pluto for a **UT** Julian Day.
    ///
    /// With an `observer`, every position is **topocentric**: the observer's
    /// geocentric position vector (WGS-84, rotated by the apparent sidereal
    /// time) is subtracted from each body's, so the diurnal parallax is exact
    /// for all of them. For the Moon that is up to a degree; for Mars at a
    /// close opposition 20"; for the Sun 9". Without an observer the places
    /// are geocentric, which is what the event solvers and almanac-style
    /// comparisons want.
    static func solarSystemObjects(
        julianDay jd: Double, observer: GeographicLocation? = nil
    ) -> [CelestialObject] {
        var objects: [CelestialObject] = []
        let frame = ApparentFrame(julianDayUT: jd)
        let earth = frame.earth
        let observerVector: SIMD3<Double>? = observer.map {
            TopocentricTransform.observerPositionEquatorial(
                observer: $0,
                localSiderealDegrees: frame.greenwichApparentSiderealDegrees + $0.longitudeDegrees
            )
        }

        /// Applies the diurnal parallax to a geocentric place at a distance.
        func topocentric(
            _ equatorial: EquatorialCoordinate, distanceKilometres: Double
        ) -> (EquatorialCoordinate, Double) {
            guard let observerVector else { return (equatorial, distanceKilometres) }
            let vector = Precession.unitVector(equatorial) * distanceKilometres - observerVector
            return (Precession.equatorial(fromVector: vector), simd_length(vector))
        }

        let sun = SunPosition.state(earth: earth)
        let sunDistanceKm = sun.radiusVectorAU * AstronomicalConstants.astronomicalUnitKilometres
        let (sunEq, sunTopoDistance) = topocentric(sun.equatorial, distanceKilometres: sunDistanceKm)
        objects.append(CelestialObject(
            id: "sun",
            name: "Sun",
            kind: .sun,
            equatorial: sunEq,
            magnitude: SunPosition.magnitude(radiusVectorAU: sun.radiusVectorAU),
            distanceKilometres: sunTopoDistance
        ))

        let moon = MoonPosition.geocentricState(earth: earth)
        let (moonEq, moonDistance) = topocentric(moon.equatorial, distanceKilometres: moon.distanceKilometres)
        // Phase from the topocentric places, which is what the observer sees.
        let moonPhaseAngle = Angle.radiansToDegrees(acos(
            -MoonPhase.cosineOfElongation(sun: sunEq, moon: moonEq)
        ))
        objects.append(CelestialObject(
            id: "moon",
            name: "Moon",
            kind: .moon,
            equatorial: moonEq,
            magnitude: MoonPosition.magnitude(
                phaseAngleDegrees: moonPhaseAngle, distanceKilometres: moonDistance
            ),
            distanceKilometres: moonDistance,
            illuminatedFraction: MoonPhase.illuminatedFraction(sun: sunEq, moon: moonEq)
        ))

        for planet in Planet.allCases {
            let state = PlanetPosition.state(planet: planet, earth: earth)
            let distanceKm = state.geocentricDistanceAU * AstronomicalConstants.astronomicalUnitKilometres
            let (planetEq, planetDistance) = topocentric(state.equatorial, distanceKilometres: distanceKm)
            var object = CelestialObject(
                id: planet.rawValue,
                name: planet.displayName,
                kind: planet.isDwarfPlanet ? .dwarfPlanet : .planet,
                equatorial: planetEq,
                magnitude: state.magnitude,
                distanceKilometres: planetDistance,
                illuminatedFraction: state.illuminatedFraction
            )
            object.phaseAngleDegrees = state.phaseAngleDegrees
            object.elongationDegrees = state.elongationDegrees
            objects.append(object)
        }

        return objects
    }

    /// A planet's magnitude for the "Tonight" planner, at the given instant.
    static func approximateMagnitudeForPlanning(_ planet: Planet, julianDay jd: Double) -> Double {
        PlanetPosition.state(planet: planet, julianDay: jd).magnitude
    }
}
