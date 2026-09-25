//
//  Nutation.swift
//  Astronomy
//
//  Nutation and the obliquity of the ecliptic: the difference between the
//  *mean* equator and equinox of date, which precession alone produces, and
//  the *true* ones the sky is actually referred to at a given instant.
//
//  Precession is the slow 26,000-year circle of the Earth's axis; nutation is
//  the 18.6-year wobble the Moon superimposes on it, up to 17 arcseconds in
//  longitude and 9 in obliquity. At the widest field this app draws it is
//  invisible. At the narrowest — half a degree across on a 1500-pixel-wide
//  window, about 1.2 arcseconds per pixel — it is fourteen pixels, and a
//  conjunction of a planet with a catalogue star renders in the wrong place
//  without it. It is also what turns mean sidereal time into apparent
//  sidereal time (the "equation of the equinoxes"), so the same terms fix the
//  hour angle of every object at once.
//
//  Reference: Jean Meeus, "Astronomical Algorithms", 2nd ed., Chapter 22.
//  The abridged series (p. 144) is used: accurate to 0.5" in Δψ and 0.1" in
//  Δε, which is comfortably under a pixel at every field of view offered. The
//  obliquity is Laskar's polynomial (Meeus 22.3), good to 0.01" over the
//  1800-2050 window.
//

import Foundation
import simd

enum Nutation {

    /// Nutation in longitude and obliquity, and the obliquity itself, at one
    /// instant. Angles in degrees.
    struct Angles: Equatable {
        /// Δψ, nutation in longitude.
        let deltaPsiDegrees: Double
        /// Δε, nutation in obliquity.
        let deltaEpsilonDegrees: Double
        /// ε₀, the mean obliquity of the ecliptic.
        let meanObliquityDegrees: Double
        /// ε = ε₀ + Δε, the true obliquity.
        var trueObliquityDegrees: Double { meanObliquityDegrees + deltaEpsilonDegrees }

        /// The equation of the equinoxes, Δψ cos ε, in degrees: what is added
        /// to mean sidereal time to get apparent sidereal time (Meeus 12.4).
        var equationOfEquinoxesDegrees: Double {
            deltaPsiDegrees * cos(Angle.degreesToRadians(trueObliquityDegrees))
        }
    }

    /// Meeus 22.3: mean obliquity in degrees, Laskar's polynomial. `t` in
    /// Julian centuries (TT) from J2000.0; accurate to 0.01" for |t| < 1.
    static func meanObliquityDegrees(julianCenturies t: Double) -> Double {
        let u = t / 100.0
        let arcseconds = -4680.93 * u
            - 1.55 * pow(u, 2)
            + 1999.25 * pow(u, 3)
            - 51.38 * pow(u, 4)
            - 249.67 * pow(u, 5)
            - 39.05 * pow(u, 6)
            + 7.12 * pow(u, 7)
            + 27.87 * pow(u, 8)
            + 5.79 * pow(u, 9)
            + 2.45 * pow(u, 10)
        return 23.0 + 26.0 / 60.0 + 21.448 / 3600.0 + arcseconds / 3600.0
    }

    /// Nutation angles for a **TT** Julian Day. The Δψ/Δε series is the
    /// abridged form of Meeus Chapter 22 (four terms), keyed on the longitude
    /// of the Moon's ascending node and the mean longitudes of the Sun and
    /// Moon.
    static func angles(julianDayTT jd: Double) -> Angles {
        let t = JulianDate.julianCenturies(fromJulianDay: jd)

        let omega = Angle.degreesToRadians(Angle.normalizeDegrees(
            125.04452 - 1934.136261 * t + 0.0020708 * t * t + t * t * t / 450_000.0
        ))
        let sunLongitude = Angle.degreesToRadians(Angle.normalizeDegrees(
            280.4665 + 36000.7698 * t
        ))
        let moonLongitude = Angle.degreesToRadians(Angle.normalizeDegrees(
            218.3165 + 481267.8813 * t
        ))

        let deltaPsiArcsec = -17.20 * sin(omega)
            - 1.32 * sin(2 * sunLongitude)
            - 0.23 * sin(2 * moonLongitude)
            + 0.21 * sin(2 * omega)
        let deltaEpsilonArcsec = 9.20 * cos(omega)
            + 0.57 * cos(2 * sunLongitude)
            + 0.10 * cos(2 * moonLongitude)
            - 0.09 * cos(2 * omega)

        return Angles(
            deltaPsiDegrees: deltaPsiArcsec / 3600.0,
            deltaEpsilonDegrees: deltaEpsilonArcsec / 3600.0,
            meanObliquityDegrees: meanObliquityDegrees(julianCenturies: t)
        )
    }

    // MARK: - Frame rotations

    /// Rotation taking ecliptic Cartesian coordinates (x toward the equinox,
    /// z toward the ecliptic pole) to equatorial ones, for an obliquity in
    /// degrees. Meeus 13.3/13.4 in matrix form.
    static func eclipticToEquatorial(obliquityDegrees: Double) -> simd_double3x3 {
        let e = Angle.degreesToRadians(obliquityDegrees)
        let c = cos(e), s = sin(e)
        // Rows: (1, 0, 0), (0, c, -s), (0, s, c); simd takes columns.
        return simd_double3x3(
            SIMD3(1, 0, 0),
            SIMD3(0, c, s),
            SIMD3(0, -s, c)
        )
    }

    /// Rotation taking **mean** equatorial coordinates of date to **true**
    /// equatorial coordinates of date: to the ecliptic with the mean
    /// obliquity, forward by Δψ along it, and back with the true obliquity.
    ///
    /// Composed with `Precession.rotationMatrix` this is the whole J2000 ->
    /// apparent-frame reduction for a catalogue direction, short of aberration
    /// (which is not a rotation; see `ApparentFrame`).
    static func rotationMatrix(angles: Angles) -> simd_double3x3 {
        let toTrue = eclipticToEquatorial(obliquityDegrees: angles.trueObliquityDegrees)
        let fromMean = eclipticToEquatorial(obliquityDegrees: angles.meanObliquityDegrees).transpose
        let psi = Angle.degreesToRadians(angles.deltaPsiDegrees)
        let c = cos(psi), s = sin(psi)
        // Rotation about the ecliptic pole by +Δψ in longitude.
        let alongEcliptic = simd_double3x3(
            SIMD3(c, s, 0),
            SIMD3(-s, c, 0),
            SIMD3(0, 0, 1)
        )
        return toTrue * alongEcliptic * fromMean
    }
}
