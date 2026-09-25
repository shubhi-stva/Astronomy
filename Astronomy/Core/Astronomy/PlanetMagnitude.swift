//
//  PlanetMagnitude.swift
//  Astronomy
//
//  Apparent visual magnitudes of the planets as functions of distance and
//  phase angle.
//
//  Source: A. Mallama & J. L. Hilton, "Computing apparent planetary magnitudes
//  for The Astronomical Almanac", Astronomy and Computing 25, 10 (2018) — the
//  polynomials adopted by the Almanac from 2019. Each is
//
//      V = 5 log₁₀(r Δ) + V₁(α)
//
//  with r and Δ the heliocentric and geocentric distances in AU and α the
//  phase angle in degrees. The polynomials are fits to photometry, valid over
//  the phase-angle range each planet reaches as seen from Earth (given in the
//  paper and enforced by clamping here).
//
//  What is omitted: the small dependence of Uranus's brightness on its
//  sub-Earth latitude (≤ 0.07 mag) and Saturn's on the sub-solar as opposed
//  to sub-Earth ring tilt. Pluto uses the classic H = −1.0 with a linear phase
//  coefficient, since Mallama & Hilton do not cover it.
//
//  Why this matters beyond the info panel: the renderer sizes and blooms a
//  planet by its magnitude, so Mars going from +1.8 at conjunction to −2.9 at
//  a perihelic opposition — a factor of 75 in brightness — is now something
//  the sky shows.
//

import Foundation

enum PlanetMagnitude {

    static func apparentMagnitude(
        planet: Planet,
        heliocentricDistanceAU r: Double,
        geocentricDistanceAU delta: Double,
        phaseAngleDegrees alpha: Double,
        saturnRingTiltDegrees ringTilt: Double = 0
    ) -> Double {
        let distanceTerm = 5 * log10(max(r * delta, 1e-12))
        let a = max(0.0, min(180.0, alpha))
        let phaseTerm: Double
        switch planet {
        case .mercury:
            phaseTerm = -0.613 + 6.3280e-2 * a - 1.6336e-3 * pow(a, 2) + 3.3644e-5 * pow(a, 3)
                - 3.4265e-7 * pow(a, 4) + 1.6893e-9 * pow(a, 5) - 3.0334e-12 * pow(a, 6)
        case .venus:
            if a <= 163.7 {
                phaseTerm = -4.384 - 1.044e-3 * a + 3.687e-4 * pow(a, 2) - 2.814e-6 * pow(a, 3) + 8.938e-9 * pow(a, 4)
            } else {
                phaseTerm = 236.05828 - 2.81914 * a + 8.39034e-3 * pow(a, 2)
            }
        case .mars:
            if a <= 50 {
                phaseTerm = -1.601 + 0.02267 * a - 0.0001302 * pow(a, 2)
            } else {
                phaseTerm = -0.367 - 0.02573 * a + 0.0003445 * pow(a, 2)
            }
        case .jupiter:
            // Jupiter never exceeds α ≈ 12° from Earth; the wide-angle branch
            // of the paper is for spacecraft.
            let alphaClamped = min(a, 12.0)
            phaseTerm = -9.395 - 3.7e-4 * alphaClamped + 6.16e-4 * pow(alphaClamped, 2)
        case .saturn:
            // Globe plus rings, α ≤ 6.5°, β the ring-plane tilt (sub-Earth
            // saturnicentric latitude), in radians inside the sines.
            let beta = Angle.degreesToRadians(abs(ringTilt))
            let alphaClamped = min(a, 6.5)
            phaseTerm = -8.914 - 1.825 * sin(beta) + 0.026 * alphaClamped
                - 0.378 * sin(beta) * exp(-2.25 * alphaClamped)
        case .uranus:
            phaseTerm = -7.110 + 6.587e-3 * a + 1.045e-4 * pow(a, 2)
        case .neptune:
            phaseTerm = -7.00 + 7.944e-3 * a + 9.617e-5 * pow(a, 2)
        case .pluto:
            // Absolute magnitude H ≈ −1.0 (JPL SBDB), phase coefficient
            // 0.04 mag/degree over the ≤ 2° range Pluto reaches from Earth.
            phaseTerm = -1.0 + 0.04 * a
        }
        return distanceTerm + phaseTerm
    }
}

/// The geometry of Saturn's ring system as seen from Earth.
///
/// Meeus, *Astronomical Algorithms*, 2nd ed., Chapter 45. The ring plane is
/// Saturn's equatorial plane; its pole has ecliptic-of-date coordinates
/// (Ω − 90°, 90° − i) with the inclination i and node Ω below.
enum SaturnRings {

    /// Inclination of the ring plane to the ecliptic of date, degrees.
    static func inclinationDegrees(julianCenturiesTT t: Double) -> Double {
        28.075216 - 0.012998 * t + 0.000004 * t * t
    }

    /// Longitude of the ascending node of the ring plane on the ecliptic of
    /// date, degrees.
    static func ascendingNodeDegrees(julianCenturiesTT t: Double) -> Double {
        169.508470 + 1.394681 * t + 0.000412 * t * t
    }

    /// Saturnicentric latitude of the Earth referred to the ring plane, B, in
    /// degrees (Meeus 45.1, Eq. for B). Positive when the northern face of
    /// the rings is toward Earth; zero when they are edge-on, which happens
    /// twice per 29.5-year orbit (most recently March 2025).
    static func ringPlaneTiltDegrees(
        geocentricEclipticOfDate g: SIMD3<Double>, julianCenturiesTT t: Double
    ) -> Double {
        let lambda = atan2(g.y, g.x)
        let beta = atan2(g.z, (g.x * g.x + g.y * g.y).squareRoot())
        let i = Angle.degreesToRadians(inclinationDegrees(julianCenturiesTT: t))
        let omega = Angle.degreesToRadians(ascendingNodeDegrees(julianCenturiesTT: t))
        let sinB = sin(i) * cos(beta) * sin(lambda - omega) - cos(i) * sin(beta)
        return Angle.radiansToDegrees(asin(max(-1.0, min(1.0, sinB))))
    }

    /// Unit vector of the ring plane's north pole in ecliptic-of-date
    /// coordinates.
    static func poleDirectionEcliptic(julianCenturiesTT t: Double) -> SIMD3<Double> {
        let lambda0 = Angle.degreesToRadians(ascendingNodeDegrees(julianCenturiesTT: t) - 90.0)
        let beta0 = Angle.degreesToRadians(90.0 - inclinationDegrees(julianCenturiesTT: t))
        let cb = cos(beta0)
        return SIMD3(cb * cos(lambda0), cb * sin(lambda0), sin(beta0))
    }
}
