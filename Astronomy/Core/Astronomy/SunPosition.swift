//
//  SunPosition.swift
//  Astronomy
//
//  Geocentric apparent position of the Sun.
//
//  The Sun is the Earth's heliocentric position negated: VSOP87 gives the
//  Earth's ecliptic longitude L, latitude B and radius R of date, and the
//  Sun's geocentric longitude is L + 180°, its latitude −B (Meeus, Ch. 25,
//  "higher accuracy"). `EarthState` then applies the FK5 correction, nutation
//  and aberration, exactly as it does for the planets, so the Sun is reduced
//  in the same frame as everything else in the sky. Accuracy is about 1".
//
//  This replaced the reduced-precision method of Meeus Ch. 25 (0.01°, or 36"),
//  which was the largest remaining error in where the Sun was drawn and, more
//  visibly, in where its light fell on the Moon's terminator.
//

import Foundation
import simd

enum SunPosition {

    /// Everything about the Sun at one instant.
    struct State: Sendable {
        /// Apparent RA/Dec, true equator and equinox of date.
        let equatorial: EquatorialCoordinate
        /// Apparent geocentric ecliptic longitude of date, degrees. What the
        /// season and phase solvers work in.
        let apparentLongitudeDegrees: Double
        /// Earth-Sun distance, AU.
        let radiusVectorAU: Double
    }

    /// The Sun's apparent geocentric RA/Dec for a **UT** Julian Day.
    static func equatorialCoordinate(julianDay jd: Double) -> EquatorialCoordinate {
        state(julianDay: jd).equatorial
    }

    static func state(julianDay jd: Double) -> State {
        state(earth: EarthState(julianDayUT: jd))
    }

    /// The Sun as seen from an already-computed Earth. The ephemeris facade
    /// uses this so every body in a frame shares one `EarthState`.
    static func state(earth: EarthState) -> State {
        // Geocentric Sun = −(heliocentric Earth). The Sun sits at the origin,
        // so there is no light-time displacement; aberration is the whole of
        // the 20.5" correction (Meeus 25.10).
        let geocentric = -earth.position
        let equatorial = earth.apparentEquatorial(geocentricEcliptic: geocentric)
        let longitude = Angle.normalizeDegrees(
            Angle.radiansToDegrees(earth.heliocentric.longitude) + 180.0
                + earth.nutation.deltaPsiDegrees
                - 20.4898 / 3600.0 / earth.heliocentric.radius
        )
        return State(
            equatorial: equatorial,
            apparentLongitudeDegrees: longitude,
            radiusVectorAU: earth.heliocentric.radius
        )
    }

    /// Earth-Sun distance in astronomical units. Varies between about 0.9833
    /// AU (perihelion, early January) and 1.0167 AU (aphelion, early July) — a
    /// 3.4% swing in the Sun's apparent diameter, visible once you zoom in.
    static func radiusVectorAU(julianDay jd: Double) -> Double {
        VSOP87.heliocentric(.earth, julianDayTT: DeltaT.terrestrialJulianDay(fromUniversal: jd)).radius
    }

    /// Apparent magnitude of the Sun at the given distance: −26.74 at 1 AU.
    static func magnitude(radiusVectorAU r: Double) -> Double {
        -26.74 + 5 * log10(max(r, 1e-9))
    }
}

/// One astronomical unit in kilometres (IAU 2012 defining value).
enum AstronomicalConstants {
    static let astronomicalUnitKilometres = 149_597_870.7
}
