//
//  MoonPosition.swift
//  Astronomy
//
//  Geocentric and topocentric position of the Moon.
//
//  The series is the full one from Jean Meeus, "Astronomical Algorithms",
//  2nd ed., Chapter 47 — Table 47.A (60 terms in longitude and distance) and
//  Table 47.B (60 terms in latitude) plus the three additive terms for the
//  action of Venus, Jupiter and the flattening of the Earth. Meeus quotes its
//  accuracy at about 10" in longitude and 4" in latitude, and the comparison
//  with JPL Horizons in `AccuracyTests` bears that out.
//
//  This replaced a ten-term truncation (0.2-0.3° error — half a Moon
//  diameter, and visibly wrong the moment the Moon passed a bright star) and,
//  with it, the app's single largest positional error: **topocentric
//  parallax**. The Moon is close enough that where it appears depends on
//  where on the Earth you stand — by up to a full degree, two Moon widths,
//  for an observer who sees it on the horizon. `topocentricEquatorial`
//  applies it exactly, by subtracting the observer's geocentric position
//  vector (WGS-84 ellipsoid, rotated by the apparent sidereal time) from the
//  Moon's; `EphemerisService` does the same for every solar-system body, and
//  for the Moon it is the difference between drawing it in the right place
//  and not.
//
//  Times: the series wants TT; every entry point takes UT and converts.
//

import Foundation
import simd

enum MoonPosition {

    /// Geocentric ecliptic position of date, plus the pieces the phase and
    /// libration code need.
    struct GeocentricState: Sendable {
        /// Apparent geocentric longitude of date (nutation applied), degrees.
        let apparentLongitudeDegrees: Double
        /// Geocentric latitude, degrees.
        let latitudeDegrees: Double
        /// Earth-Moon centre distance, km.
        let distanceKilometres: Double
        /// Apparent RA/Dec, true equator and equinox of date.
        let equatorial: EquatorialCoordinate
        /// The Moon's mean longitude L', degrees — used by the phase solver.
        let meanLongitudeDegrees: Double
    }

    // MARK: - Series (Meeus Tables 47.A and 47.B)

    /// (D, M, M', F, Σl coefficient in 1e-6 degrees, Σr coefficient in 1e-3 km)
    private static let longitudeAndDistanceTerms: [(Int, Int, Int, Int, Double, Double)] = [
        (0, 0, 1, 0, 6288774, -20905355), (2, 0, -1, 0, 1274027, -3699111),
        (2, 0, 0, 0, 658314, -2955968), (0, 0, 2, 0, 213618, -569925),
        (0, 1, 0, 0, -185116, 48888), (0, 0, 0, 2, -114332, -3149),
        (2, 0, -2, 0, 58793, 246158), (2, -1, -1, 0, 57066, -152138),
        (2, 0, 1, 0, 53322, -170733), (2, -1, 0, 0, 45758, -204586),
        (0, 1, -1, 0, -40923, -129620), (1, 0, 0, 0, -34720, 108743),
        (0, 1, 1, 0, -30383, 104755), (2, 0, 0, -2, 15327, 10321),
        (0, 0, 1, 2, -12528, 0), (0, 0, 1, -2, 10980, 79661),
        (4, 0, -1, 0, 10675, -34782), (0, 0, 3, 0, 10034, -23210),
        (4, 0, -2, 0, 8548, -21636), (2, 1, -1, 0, -7888, 24208),
        (2, 1, 0, 0, -6766, 30824), (1, 0, -1, 0, -5163, -8379),
        (1, 1, 0, 0, 4987, -16675), (2, -1, 1, 0, 4036, -12831),
        (2, 0, 2, 0, 3994, -10445), (4, 0, 0, 0, 3861, -11650),
        (2, 0, -3, 0, 3665, 14403), (0, 1, -2, 0, -2689, -7003),
        (2, 0, -1, 2, -2602, 0), (2, -1, -2, 0, 2390, 10056),
        (1, 0, 1, 0, -2348, 6322), (2, -2, 0, 0, 2236, -9884),
        (0, 1, 2, 0, -2120, 5751), (0, 2, 0, 0, -2069, 0),
        (2, -2, -1, 0, 2048, -4950), (2, 0, 1, -2, -1773, 4130),
        (2, 0, 0, 2, -1595, 0), (4, -1, -1, 0, 1215, -3958),
        (0, 0, 2, 2, -1110, 0), (3, 0, -1, 0, -892, 3258),
        (2, 1, 1, 0, -810, 2616), (4, -1, -2, 0, 759, -1897),
        (0, 2, -1, 0, -713, -2117), (2, 2, -1, 0, -700, 2354),
        (2, 1, -2, 0, 691, 0), (2, -1, 0, -2, 596, 0),
        (4, 0, 1, 0, 549, -1423), (0, 0, 4, 0, 537, -1117),
        (4, -1, 0, 0, 520, -1571), (1, 0, -2, 0, -487, -1739),
        (2, 1, 0, -2, -399, 0), (0, 0, 2, -2, -381, -4421),
        (1, 1, 1, 0, 351, 0), (3, 0, -2, 0, -340, 0),
        (4, 0, -3, 0, 330, 0), (2, -1, 2, 0, 327, 0),
        (0, 2, 1, 0, -323, 1165), (1, 1, -1, 0, 299, 0),
        (2, 0, 3, 0, 294, 0), (2, 0, -1, -2, 0, 8752),
    ]

    /// (D, M, M', F, Σb coefficient in 1e-6 degrees)
    private static let latitudeTerms: [(Int, Int, Int, Int, Double)] = [
        (0, 0, 0, 1, 5128122), (0, 0, 1, 1, 280602), (0, 0, 1, -1, 277693),
        (2, 0, 0, -1, 173237), (2, 0, -1, 1, 55413), (2, 0, -1, -1, 46271),
        (2, 0, 0, 1, 32573), (0, 0, 2, 1, 17198), (2, 0, 1, -1, 9266),
        (0, 0, 2, -1, 8822), (2, -1, 0, -1, 8216), (2, 0, -2, -1, 4324),
        (2, 0, 1, 1, 4200), (2, 1, 0, -1, -3359), (2, -1, -1, 1, 2463),
        (2, -1, 0, 1, 2211), (2, -1, -1, -1, 2065), (0, 1, -1, -1, -1870),
        (4, 0, -1, -1, 1828), (0, 1, 0, 1, -1794), (0, 0, 0, 3, -1749),
        (0, 1, -1, 1, -1565), (1, 0, 0, 1, -1491), (0, 1, 1, 1, -1475),
        (0, 1, 1, -1, -1410), (0, 1, 0, -1, -1344), (1, 0, 0, -1, -1335),
        (0, 0, 3, 1, 1107), (4, 0, 0, -1, 1021), (4, 0, -1, 1, 833),
        (0, 0, 1, -3, 777), (4, 0, -2, 1, 671), (2, 0, 0, -3, 607),
        (2, 0, 2, -1, 596), (2, -1, 1, -1, 491), (2, 0, -2, 1, -451),
        (0, 0, 3, -1, 439), (2, 0, 2, 1, 422), (2, 0, -3, -1, 421),
        (2, 1, -1, 1, -366), (2, 1, 0, 1, -351), (4, 0, 0, 1, 331),
        (2, -1, 1, 1, 315), (2, -2, 0, -1, 302), (0, 0, 1, 3, -283),
        (2, 1, 1, -1, -229), (1, 1, 0, -1, 223), (1, 1, 0, 1, 223),
        (0, 1, -2, -1, -220), (2, 1, -1, -1, -220), (1, 0, 1, 1, -185),
        (2, -1, -2, -1, 181), (0, 1, 2, 1, -177), (4, 0, -2, -1, 176),
        (4, -1, -1, -1, 166), (1, 0, 1, -1, -164), (4, 0, 1, -1, 132),
        (1, 0, -1, -1, -119), (4, -1, 0, -1, 115), (2, -2, 0, 1, 107),
    ]

    /// The fundamental arguments (Meeus 47.1-47.5), degrees, for `t` in
    /// Julian centuries TT.
    private struct Arguments {
        let lPrime, d, m, mPrime, f, e: Double
        init(t: Double) {
            let t2 = t * t, t3 = t2 * t, t4 = t3 * t
            lPrime = Angle.normalizeDegrees(
                218.3164477 + 481267.88123421 * t - 0.0015786 * t2 + t3 / 538841.0 - t4 / 65_194_000.0
            )
            d = Angle.normalizeDegrees(
                297.8501921 + 445267.1114034 * t - 0.0018819 * t2 + t3 / 545868.0 - t4 / 113_065_000.0
            )
            m = Angle.normalizeDegrees(357.5291092 + 35999.0502909 * t - 0.0001536 * t2 + t3 / 24_490_000.0)
            mPrime = Angle.normalizeDegrees(
                134.9633964 + 477198.8675055 * t + 0.0087414 * t2 + t3 / 69699.0 - t4 / 14_712_000.0
            )
            f = Angle.normalizeDegrees(
                93.2720950 + 483202.0175233 * t - 0.0036539 * t2 - t3 / 3_526_000.0 + t4 / 863_310_000.0
            )
            // Eccentricity of the Earth's orbit is decreasing: terms in M
            // carry E, terms in 2M carry E² (Meeus 47.6).
            e = 1 - 0.002516 * t - 0.0000074 * t2
        }
    }

    // MARK: - Geocentric

    /// Geocentric apparent RA/Dec for a **UT** Julian Day.
    static func equatorialCoordinate(julianDay jd: Double) -> EquatorialCoordinate {
        geocentricState(julianDay: jd).equatorial
    }

    /// Geocentric distance to the Moon's centre, km, for a UT Julian Day.
    static func distanceKilometres(julianDay jd: Double) -> Double {
        geocentricState(julianDay: jd).distanceKilometres
    }

    static func geocentricState(julianDay jd: Double) -> GeocentricState {
        geocentricState(earth: EarthState(julianDayUT: jd))
    }

    static func geocentricState(earth: EarthState) -> GeocentricState {
        let t = earth.julianCenturiesTT
        let a = Arguments(t: t)
        let toRadians = Double.pi / 180.0
        let dR = a.d * toRadians, mR = a.m * toRadians
        let mpR = a.mPrime * toRadians, fR = a.f * toRadians

        var sigmaL = 0.0, sigmaR = 0.0, sigmaB = 0.0
        for (cd, cm, cmp, cf, l, r) in longitudeAndDistanceTerms {
            let argument = Double(cd) * dR + Double(cm) * mR + Double(cmp) * mpR + Double(cf) * fR
            let eFactor = cm == 0 ? 1.0 : (abs(cm) == 1 ? a.e : a.e * a.e)
            sigmaL += l * eFactor * sin(argument)
            sigmaR += r * eFactor * cos(argument)
        }
        for (cd, cm, cmp, cf, b) in latitudeTerms {
            let argument = Double(cd) * dR + Double(cm) * mR + Double(cmp) * mpR + Double(cf) * fR
            let eFactor = cm == 0 ? 1.0 : (abs(cm) == 1 ? a.e : a.e * a.e)
            sigmaB += b * eFactor * sin(argument)
        }

        // Additive terms: Venus (A1), Jupiter (A2), and the Earth's flattening
        // (the L' − F terms). Meeus p. 338.
        let a1 = Angle.normalizeDegrees(119.75 + 131.849 * t) * toRadians
        let a2 = Angle.normalizeDegrees(53.09 + 479264.290 * t) * toRadians
        let a3 = Angle.normalizeDegrees(313.45 + 481266.484 * t) * toRadians
        let lpR = a.lPrime * toRadians
        sigmaL += 3958 * sin(a1) + 1962 * sin(lpR - fR) + 318 * sin(a2)
        sigmaB += -2235 * sin(lpR) + 382 * sin(a3) + 175 * sin(a1 - fR) + 175 * sin(a1 + fR)
            + 127 * sin(lpR - mpR) - 115 * sin(lpR + mpR)

        let longitude = a.lPrime + sigmaL / 1_000_000.0
        let latitude = sigmaB / 1_000_000.0
        let distance = 385_000.56 + sigmaR / 1000.0

        // Apparent longitude: add the nutation in longitude, then convert with
        // the true obliquity. No aberration: for the Moon, light-time and
        // stellar aberration cancel to under an arcsecond.
        let apparentLongitude = Angle.normalizeDegrees(longitude + earth.nutation.deltaPsiDegrees)
        let lambda = apparentLongitude * toRadians
        let beta = latitude * toRadians
        let cb = cos(beta)
        let ecliptic = SIMD3(cb * cos(lambda), cb * sin(lambda), sin(beta))
        let equatorial = Precession.equatorial(fromVector: earth.eclipticToEquatorial * ecliptic)

        return GeocentricState(
            apparentLongitudeDegrees: apparentLongitude,
            latitudeDegrees: latitude,
            distanceKilometres: distance,
            equatorial: equatorial,
            meanLongitudeDegrees: a.lPrime
        )
    }

    // MARK: - Topocentric

    /// The Moon as seen from a place on the Earth's surface rather than from
    /// its centre: apparent RA/Dec and distance with the diurnal parallax
    /// applied.
    ///
    /// Done as a vector subtraction (Meeus Ch. 40 gives the same thing in
    /// trigonometric form): the Moon's geocentric position vector in the true
    /// equatorial frame of date, minus the observer's geocentric position in
    /// the same frame — the WGS-84 ellipsoid rotated by the local apparent
    /// sidereal time — is the observer-to-Moon vector. Its direction is the
    /// topocentric place and its length the topocentric distance, which is
    /// also what the apparent diameter should be sized from (the Moon is
    /// closer by up to an Earth radius, 1.7%, when overhead).
    static func topocentric(
        geocentric: GeocentricState,
        observer: GeographicLocation,
        julianDayUT: Double,
        apparentSiderealDegrees: Double
    ) -> (equatorial: EquatorialCoordinate, distanceKilometres: Double) {
        let direction = Precession.unitVector(geocentric.equatorial)
        let geocentricVector = direction * geocentric.distanceKilometres
        let observerVector = TopocentricTransform.observerPositionEquatorial(
            observer: observer, localSiderealDegrees: apparentSiderealDegrees + observer.longitudeDegrees
        )
        let topocentricVector = geocentricVector - observerVector
        return (
            Precession.equatorial(fromVector: topocentricVector),
            simd_length(topocentricVector)
        )
    }

    /// Topocentric apparent RA/Dec for a UT Julian Day and an observer.
    static func topocentricEquatorial(
        julianDay jd: Double, observer: GeographicLocation
    ) -> EquatorialCoordinate {
        let frame = ApparentFrame(julianDayUT: jd)
        let geocentric = geocentricState(earth: frame.earth)
        return topocentric(
            geocentric: geocentric, observer: observer, julianDayUT: jd,
            apparentSiderealDegrees: frame.greenwichApparentSiderealDegrees
        ).equatorial
    }

    /// Apparent visual magnitude of the Moon.
    ///
    /// Allen's *Astrophysical Quantities* phase law, −12.73 at full and mean
    /// distance, with the 0.026·|α| + 4×10⁻⁹·α⁴ phase-angle dependence (the
    /// quartic is what makes the crescent so much fainter than half the full
    /// brightness), scaled by the inverse-square distance term.
    static func magnitude(phaseAngleDegrees alpha: Double, distanceKilometres: Double) -> Double {
        let a = abs(alpha)
        let phase = 0.026 * a + 4e-9 * pow(a, 4)
        let distance = 5 * log10(max(distanceKilometres, 1) / 384_400.0)
        return -12.73 + phase + distance
    }
}
