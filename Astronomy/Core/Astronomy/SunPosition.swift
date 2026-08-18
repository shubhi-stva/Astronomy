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

    /// Earth-Sun distance (the Sun's radius vector R) in astronomical units.
    ///
    /// Meeus, *Astronomical Algorithms*, 2nd ed., eq. 25.5:
    ///
    ///     R = 1.000001018 * (1 - e^2) / (1 + e * cos(nu))
    ///
    /// where `nu` is the Sun's true anomaly (mean anomaly plus the equation of
    /// centre). Varies between about 0.9833 AU (perihelion, early January) and
    /// 1.0167 AU (aphelion, early July), which is a 3.4% swing in the Sun's
    /// apparent angular diameter — visible once you zoom in.
    static func radiusVectorAU(julianDay jd: Double) -> Double {
        let t = JulianDate.julianCenturies(fromJulianDay: jd)

        let m = Angle.normalizeDegrees(357.52911 + 35999.05029 * t - 0.0001537 * t * t)
        let mRad = Angle.degreesToRadians(m)
        let e = 0.016708634 - 0.000042037 * t - 0.0000001267 * t * t

        let c = (1.914602 - 0.004817 * t - 0.000014 * t * t) * sin(mRad)
            + (0.019993 - 0.000101 * t) * sin(2 * mRad)
            + 0.000289 * sin(3 * mRad)

        let nu = Angle.degreesToRadians(m + c)
        return 1.000001018 * (1 - e * e) / (1 + e * cos(nu))
    }
}

/// One astronomical unit in kilometres (IAU 2012 defining value).
enum AstronomicalConstants {
    static let astronomicalUnitKilometres = 149_597_870.7
}
