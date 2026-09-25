//
//  ObjectFacts.swift
//  Astronomy
//
//  What the info panel says about a selected object beyond its name and
//  coordinates: where it is in the observer's sky, which constellation it is
//  in, when it rises and sets, how far away it is and how big it looks.
//
//  Split in two because the two halves change at very different rates. The
//  *live* facts (altitude, azimuth) move every second and cost a single
//  transform. The *daily* facts (rise, transit, set, constellation) cost a
//  root-find over a day of ephemeris and change only when the day, the place
//  or the object does, so `SkyViewModel` caches them on exactly that key.
//

import Foundation
import simd

struct ObjectFacts: Equatable, Sendable {

    struct Live: Equatable, Sendable {
        /// Geometric altitude and azimuth.
        let horizontal: HorizontalCoordinate
        /// Altitude with refraction, when the sky is drawn with it.
        let apparentAltitudeDegrees: Double
        /// Above the true horizon.
        var isUp: Bool { horizontal.altitudeDegrees > 0 }
    }

    struct Daily: Equatable, Sendable {
        let riseJulianDay: Double?
        let transitJulianDay: Double?
        let setJulianDay: Double?
        let transitAltitudeDegrees: Double?
        let circumstance: RiseSetCalculator.Circumstance?
        /// IAU abbreviation of the containing constellation ("Ori").
        let constellationAbbreviation: String?
    }

    var live: Live
    var daily: Daily?

    /// Human-readable distance: kilometres for the Moon and satellites,
    /// astronomical units plus light-time for everything farther.
    static func distanceDescription(kilometres km: Double) -> String {
        let au = km / AstronomicalConstants.astronomicalUnitKilometres
        if au < 0.02 {
            return String(format: "%@ km", Self.grouped(km))
        }
        let lightSeconds = km / 299_792.458
        let lightTime: String
        if lightSeconds < 120 {
            lightTime = String(format: "%.0f light-seconds", lightSeconds)
        } else if lightSeconds < 7200 {
            lightTime = String(format: "%.1f light-minutes", lightSeconds / 60)
        } else {
            lightTime = String(format: "%.2f light-hours", lightSeconds / 3600)
        }
        return String(format: "%.3f AU · %@", au, lightTime)
    }

    static func grouped(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }

    /// Angular diameter as arcminutes or arcseconds.
    static func angularDiameterDescription(degrees: Double) -> String {
        let arcsec = degrees * 3600
        if arcsec >= 60 {
            return String(format: "%.1f′", arcsec / 60)
        }
        return String(format: "%.1f″", arcsec)
    }

    /// The daily facts for an object. Rise/set use the same standard
    /// altitudes as the Tonight planner, over the 24 hours starting at `start`.
    static func daily(
        for object: CelestialObject,
        observer: GeographicLocation,
        startJulianDay start: Double,
        boundaries: ConstellationBoundaries?
    ) -> Daily {
        // Constellation membership is a J2000 question: solar-system places
        // are of date and are rotated back with the precession matrix (the
        // nutation and aberration left in are seconds of arc, far inside any
        // boundary).
        let j2000: EquatorialCoordinate
        switch object.kind {
        case .star, .deepSky, .constellation:
            j2000 = object.equatorial
        default:
            let inverse = Precession.rotationMatrix(julianDay: start).transpose
            j2000 = Precession.equatorial(fromVector: inverse * Precession.unitVector(object.equatorial))
        }
        let constellation = boundaries?.constellation(containing: j2000)

        let result: RiseSetCalculator.Result?
        switch object.kind {
        case .sun:
            result = RiseSetCalculator.sunEvents(observer: observer, startJulianDay: start)
        case .moon:
            result = RiseSetCalculator.moonEvents(observer: observer, startJulianDay: start)
        case .planet, .dwarfPlanet:
            if let planet = Planet(rawValue: object.id) {
                result = RiseSetCalculator.events(
                    equatorialAt: { PlanetPosition.equatorialCoordinate(planet: planet, julianDay: $0) },
                    standardAltitudeDegrees: RiseSetCalculator.StandardAltitude.point,
                    observer: observer, startJulianDay: start
                )
            } else {
                result = nil
            }
        case .star, .deepSky:
            result = RiseSetCalculator.events(
                fixedJ2000: object.equatorial, observer: observer, startJulianDay: start
            )
        // A satellite's "rise" is a pass, which the passes panel predicts
        // properly; a constellation is a region; a Galilean moon shares
        // Jupiter's. None of them has a single daily answer worth printing.
        case .satellite, .constellation, .planetMoon:
            result = nil
        }
        return Daily(
            riseJulianDay: result?.riseJulianDay,
            transitJulianDay: result?.transitJulianDay,
            setJulianDay: result?.setJulianDay,
            transitAltitudeDegrees: result?.transitAltitudeDegrees,
            circumstance: result?.circumstance,
            constellationAbbreviation: constellation
        )
    }
}
