//
//  SunPosition.swift
//  Astronomy
//
//  Low-precision geocentric apparent position of the Sun.
//
//  Reference: Jean Meeus, "Astronomical Algorithms", 2nd ed., Chapter 25
//  ("Solar Coordinates", the reduced-precision method, accurate to about
//  0.01 degree).
//

import Foundation

enum SunPosition {

    /// Computes the Sun's geocentric apparent RA/Dec for the given Julian Day.
    static func equatorialCoordinate(julianDay jd: Double) -> EquatorialCoordinate {
        let t = JulianDate.julianCenturies(fromJulianDay: jd)

        // Geometric mean longitude of the Sun (deg), referred to mean equinox of date.
        let l0 = Angle.normalizeDegrees(280.46646 + 36000.76983 * t + 0.0003032 * t * t)

        // Mean anomaly of the Sun (deg).
        let m = Angle.normalizeDegrees(357.52911 + 35999.05029 * t - 0.0001537 * t * t)
        let mRad = Angle.degreesToRadians(m)

        // Eccentricity of Earth's orbit.
        let e = 0.016708634 - 0.000042037 * t - 0.0000001267 * t * t

        // Equation of center (deg).
        let c = (1.914602 - 0.004817 * t - 0.000014 * t * t) * sin(mRad)
            + (0.019993 - 0.000101 * t) * sin(2 * mRad)
            + 0.000289 * sin(3 * mRad)

        // True longitude and true anomaly.
        let trueLongitude = l0 + c
        _ = e // Eccentricity retained for documentation / future radius-vector use.

        // Apparent longitude, correcting for nutation and aberration (approx).
        let omega = 125.04 - 1934.136 * t
        let apparentLongitude = trueLongitude - 0.00569 - 0.00478 * sin(Angle.degreesToRadians(omega))

        // Obliquity of the ecliptic, corrected for nutation (approx, Meeus 25.8/22.3).
        let meanObliquity = 23.439291 - 0.0130042 * t - 1.64e-7 * t * t + 5.04e-7 * t * t * t
        let correctedObliquity = meanObliquity + 0.00256 * cos(Angle.degreesToRadians(omega))

        let lambda = Angle.degreesToRadians(apparentLongitude)
        let epsilon = Angle.degreesToRadians(correctedObliquity)

        // Ecliptic latitude of the Sun is ~0 (ignoring perturbations).
        let rightAscensionRad = atan2(cos(epsilon) * sin(lambda), cos(lambda))
        let declinationRad = asin(sin(epsilon) * sin(lambda))

        let ra = Angle.normalizeDegrees(Angle.radiansToDegrees(rightAscensionRad))
        let dec = Angle.radiansToDegrees(declinationRad)

        return EquatorialCoordinate(rightAscensionDegrees: ra, declinationDegrees: dec)
    }
}
