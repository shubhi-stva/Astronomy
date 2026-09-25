//
//  DeltaT.swift
//  Astronomy
//
//  ΔT = TT − UT: the difference between the uniform time scale the planetary
//  and lunar theories are expressed in (Terrestrial Time) and the rotational
//  time scale the clock on the wall follows (Universal Time).
//
//  Every `julianDay` in this app is derived from `Date`, which is UTC, and UTC
//  tracks UT1 to within 0.9 s. The ephemerides — VSOP87, the lunar series,
//  the precession and nutation polynomials — want TT. The difference is about
//  69 s in the 2020s, which moves the Moon by 35 arcseconds and the Sun by
//  under 3, so it is far from cosmetic at the fields of view this app reaches.
//
//  Sidereal time, by contrast, is a function of *UT* (it is the Earth's
//  rotation angle), so it must keep being fed the UT value. The rule, applied
//  throughout `Core/`: positions of bodies use TT; where the observer is
//  looking uses UT.
//
//  Source: the polynomial expressions of Espenak & Meeus, "Five Millennium
//  Canon of Solar Eclipses" (NASA/TP-2006-214141), as published on the NASA
//  eclipse site (https://eclipse.gsfc.nasa.gov/SEcat5/deltatpoly.html). They
//  fit the historical record to a few seconds and extrapolate smoothly.
//

import Foundation

enum DeltaT {

    /// ΔT in seconds for a decimal year (e.g. 2026.5).
    static func seconds(decimalYear y: Double) -> Double {
        switch y {
        case ..<(-500):
            let u = (y - 1820) / 100
            return -20 + 32 * u * u
        case ..<500:
            let u = y / 100
            return 10583.6 - 1014.41 * u + 33.78311 * u * u - 5.952053 * pow(u, 3)
                - 0.1798452 * pow(u, 4) + 0.022174192 * pow(u, 5) + 0.0090316521 * pow(u, 6)
        case ..<1600:
            let u = (y - 1000) / 100
            return 1574.2 - 556.01 * u + 71.23472 * u * u + 0.319781 * pow(u, 3)
                - 0.8503463 * pow(u, 4) - 0.005050998 * pow(u, 5) + 0.0083572073 * pow(u, 6)
        case ..<1700:
            let t = y - 1600
            return 120 - 0.9808 * t - 0.01532 * t * t + pow(t, 3) / 7129
        case ..<1800:
            let t = y - 1700
            return 8.83 + 0.1603 * t - 0.0059285 * t * t + 0.00013336 * pow(t, 3) - pow(t, 4) / 1_174_000
        case ..<1860:
            let t = y - 1800
            return 13.72 - 0.332447 * t + 0.0068612 * t * t + 0.0041116 * pow(t, 3)
                - 0.00037436 * pow(t, 4) + 0.0000121272 * pow(t, 5)
                - 0.0000001699 * pow(t, 6) + 0.000000000875 * pow(t, 7)
        case ..<1900:
            let t = y - 1860
            return 7.62 + 0.5737 * t - 0.251754 * t * t + 0.01680668 * pow(t, 3)
                - 0.0004473624 * pow(t, 4) + pow(t, 5) / 233_174
        case ..<1920:
            let t = y - 1900
            return -2.79 + 1.494119 * t - 0.0598939 * t * t + 0.0061966 * pow(t, 3) - 0.000197 * pow(t, 4)
        case ..<1941:
            let t = y - 1920
            return 21.20 + 0.84493 * t - 0.076100 * t * t + 0.0020936 * pow(t, 3)
        case ..<1961:
            let t = y - 1950
            return 29.07 + 0.407 * t - t * t / 233 + pow(t, 3) / 2547
        case ..<1986:
            let t = y - 1975
            return 45.45 + 1.067 * t - t * t / 260 - pow(t, 3) / 718
        case ..<2000:
            let t = y - 2000
            return 63.86 + 0.3345 * t - 0.060374 * t * t + 0.0017275 * pow(t, 3)
                + 0.000651814 * pow(t, 4) + 0.00002373599 * pow(t, 5)
        case ..<2027:
            // The NASA 2005-2050 polynomial predicted a faster rise than the
            // Earth's rotation actually delivered (it gives ~75 s for 2026
            // where the IERS value is ~69 s). Observed annual values are used
            // instead, linearly interpolated; the last entries are the IERS
            // bulletins' figures rounded to a tenth of a second.
            let table: [Double] = [
                63.83, 64.09, 64.30, 64.47, 64.57, 64.69, 64.85, 65.15, 65.46, 65.78,   // 2000-2009
                66.07, 66.32, 66.60, 66.91, 67.28, 67.64, 68.10, 68.59, 68.97, 69.22,   // 2010-2019
                69.36, 69.36, 69.29, 69.20, 69.18, 69.19, 69.20,                        // 2020-2026
            ]
            let x = y - 2000
            let i = min(table.count - 2, max(0, Int(x)))
            let f = x - Double(i)
            return table[i] + (table[i + 1] - table[i]) * f
        default:
            // Beyond the observed record: a gentle quadratic rise anchored on
            // the last observed value, continuous with the table above.
            //
            // Deliberately *not* handing over to the canonical long-term
            // parabola (−20 + 32u², u in centuries from 1820) at some later
            // year. That parabola is a fit to millennia of eclipse records and
            // is simply wrong about the present era — it gives 116 s for 2026
            // against an observed 69 — so switching to it introduces a step of
            // more than two minutes, which is a sky that jumps as the time
            // machine crosses the boundary. One continuous extrapolation is
            // both honest and better behaved, and the time machine is clamped
            // to 2050 (`EphemerisService.validYearRange`) in any case, where
            // this gives about 75 s.
            let t = y - 2026
            return 69.20 + 0.10 * t + 0.006 * t * t
        }
    }

    /// ΔT in seconds at a UT Julian Day.
    static func seconds(julianDay jd: Double) -> Double {
        seconds(decimalYear: 2000.0 + (jd - JulianDate.j2000) / 365.25)
    }

    /// Terrestrial Time Julian Day for a UT Julian Day. The conversion every
    /// ephemeris entry point applies before evaluating its series.
    @inline(__always)
    static func terrestrialJulianDay(fromUniversal jd: Double) -> Double {
        jd + seconds(julianDay: jd) / 86_400.0
    }
}
