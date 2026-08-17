//
//  MoonPhase.swift
//  Astronomy
//
//  Illuminated fraction of the Moon's disk.
//
//  Reference: Jean Meeus, "Astronomical Algorithms", 2nd ed., Chapter 48
//  ("Illuminated Fraction of the Moon's Disk").
//
//  Meeus 48.2 gives the geocentric elongation psi of the Moon from the Sun
//  from their apparent equatorial coordinates:
//
//      cos(psi) = sin(dec_sun) sin(dec_moon)
//               + cos(dec_sun) cos(dec_moon) cos(ra_sun - ra_moon)
//
//  and 48.3 the phase angle i from psi and the two distances. We use the
//  first-order approximation i = 180 deg - psi, which drops the small
//  correction for the Sun/Moon distance ratio (that term shifts i by at most
//  a few tenths of a degree, changing k by well under 1% — invisible at the
//  handful-of-pixels scale we draw the Moon).
//
//  Then Meeus 48.1:  k = (1 + cos i) / 2 = (1 - cos psi) / 2.
//

import Foundation

enum MoonPhase {

    /// Illuminated fraction of the Moon's disk, 0 (new) ... 1 (full).
    static func illuminatedFraction(
        sun: EquatorialCoordinate,
        moon: EquatorialCoordinate
    ) -> Double {
        let cosPsi = cosineOfElongation(sun: sun, moon: moon)
        return min(1.0, max(0.0, (1.0 - cosPsi) / 2.0))
    }

    /// cos of the geocentric elongation between the Sun and the Moon.
    static func cosineOfElongation(
        sun: EquatorialCoordinate,
        moon: EquatorialCoordinate
    ) -> Double {
        let decSun = Angle.degreesToRadians(sun.declinationDegrees)
        let decMoon = Angle.degreesToRadians(moon.declinationDegrees)
        let deltaRA = Angle.degreesToRadians(sun.rightAscensionDegrees - moon.rightAscensionDegrees)

        let cosPsi = sin(decSun) * sin(decMoon) + cos(decSun) * cos(decMoon) * cos(deltaRA)
        return min(1.0, max(-1.0, cosPsi))
    }

    /// Waxing (illuminated limb on the side of increasing ecliptic longitude)
    /// vs waning. Derived from the sign of the Moon-minus-Sun difference in
    /// right ascension, wrapped to +/-180 deg.
    static func isWaxing(sun: EquatorialCoordinate, moon: EquatorialCoordinate) -> Bool {
        var delta = moon.rightAscensionDegrees - sun.rightAscensionDegrees
        delta = delta.truncatingRemainder(dividingBy: 360)
        if delta < 0 { delta += 360 }
        return delta < 180
    }
}
