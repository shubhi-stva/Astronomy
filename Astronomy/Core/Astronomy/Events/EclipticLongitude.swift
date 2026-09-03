//
//  EclipticLongitude.swift
//  Astronomy
//
//  Ecliptic longitude, which is the coordinate almost every calendar event in
//  this app is actually defined in.
//
//  The rest of the app works in equatorial coordinates because that is what the
//  catalogues and the renderer want. But the events are not equatorial facts:
//  an equinox is "the Sun's apparent longitude is 0", a full moon is "the Moon
//  and the Sun are 180 degrees apart *in longitude*", and a meteor shower's
//  peak is tabulated against solar longitude. Each of those is a one-dimensional
//  quantity crossing a threshold, which is exactly the shape `EventSolver` can
//  solve for; expressed in RA/Dec they would each need their own special case.
//
//  Two frames appear here and the difference matters:
//
//   * **Of date** — what the ephemerides in this app already produce, and what
//     the seasons and the lunar phases are defined against. An equinox *is* the
//     instant the apparent longitude of date reaches zero.
//   * **J2000** — what the IMO's meteor-shower table is tabulated in. By 2026
//     precession has moved the two apart by 0.36 degrees, which is nearly nine
//     hours of the Sun's motion: using the wrong one would put the Geminid peak
//     most of a night out.
//

import Foundation
import simd

enum EclipticLongitude {

    /// Mean obliquity of the ecliptic, in degrees (Meeus, *Astronomical
    /// Algorithms* 2nd ed., 22.2). The same series `SunPosition` and
    /// `MoonPosition` use, factored out so the three cannot drift.
    static func meanObliquityDegrees(julianDay jd: Double) -> Double {
        let t = JulianDate.julianCenturies(fromJulianDay: jd)
        return 23.439291 - 0.0130042 * t - 1.64e-7 * t * t + 5.04e-7 * t * t * t
    }

    /// Obliquity at J2000, for the fixed-frame conversions.
    static let j2000ObliquityDegrees = 23.4392911

    /// Ecliptic longitude of an equatorial position, given the obliquity of the
    /// frame that position is expressed in. Meeus 13.1.
    static func longitudeDegrees(
        equatorial: EquatorialCoordinate, obliquityDegrees: Double
    ) -> Double {
        let alpha = Angle.degreesToRadians(equatorial.rightAscensionDegrees)
        let delta = Angle.degreesToRadians(equatorial.declinationDegrees)
        let epsilon = Angle.degreesToRadians(obliquityDegrees)
        let lambda = atan2(
            sin(alpha) * cos(epsilon) + tan(delta) * sin(epsilon),
            cos(alpha)
        )
        return Angle.normalizeDegrees(Angle.radiansToDegrees(lambda))
    }

    /// Apparent ecliptic longitude of date, for a position already referred to
    /// the equinox of date — which is what every ephemeris in this app returns.
    static func ofDate(
        equatorialOfDate: EquatorialCoordinate, julianDay jd: Double
    ) -> Double {
        longitudeDegrees(
            equatorial: equatorialOfDate,
            obliquityDegrees: meanObliquityDegrees(julianDay: jd)
        )
    }

    /// The same position's longitude in the fixed J2000 frame: de-precess, then
    /// measure against the J2000 ecliptic.
    static func j2000(
        equatorialOfDate: EquatorialCoordinate, julianDay jd: Double
    ) -> Double {
        let toJ2000 = Precession.rotationMatrix(julianDay: jd).transpose
        let j2000Equatorial = Precession.equatorial(
            fromVector: toJ2000 * Precession.unitVector(equatorialOfDate)
        )
        return longitudeDegrees(
            equatorial: j2000Equatorial, obliquityDegrees: j2000ObliquityDegrees
        )
    }

    // MARK: - The two bodies the calendar asks about

    static func sunOfDate(julianDay jd: Double) -> Double {
        ofDate(equatorialOfDate: SunPosition.equatorialCoordinate(julianDay: jd), julianDay: jd)
    }

    /// Solar longitude in the J2000 frame — the coordinate the IMO working
    /// list tabulates meteor-shower maxima against.
    static func sunJ2000(julianDay jd: Double) -> Double {
        j2000(equatorialOfDate: SunPosition.equatorialCoordinate(julianDay: jd), julianDay: jd)
    }

    static func moonOfDate(julianDay jd: Double) -> Double {
        ofDate(equatorialOfDate: MoonPosition.equatorialCoordinate(julianDay: jd), julianDay: jd)
    }

    /// Moon minus Sun, normalised to 0...360. Zero at new moon, 180 at full.
    ///
    /// Taken as a difference of two of-date longitudes on purpose: whatever
    /// precession does, it does to both, so it cancels and the phase angle is
    /// frame-independent — as it must be, since the phase is a geometric fact
    /// about three bodies and not about a coordinate system.
    static func moonElongationOfDate(julianDay jd: Double) -> Double {
        Angle.normalizeDegrees(moonOfDate(julianDay: jd) - sunOfDate(julianDay: jd))
    }
}
