//
//  PlanetPosition.swift
//  Astronomy
//
//  Geocentric apparent positions of the planets.
//
//  Mercury through Neptune come from the VSOP87D planetary theory (see
//  `VSOP87.swift`): heliocentric ecliptic coordinates of date for the planet
//  and for the Earth, differenced to a geocentric vector, corrected for the
//  light-time (the planet is seen where it *was* when the light left it —
//  Meeus Ch. 33, iterated twice), then reduced through `EarthState` for the
//  FK5 frame correction, nutation and aberration. Against JPL Horizons this
//  is good to a few arcseconds across 1800-2050.
//
//  Pluto is the exception. VSOP87 does not include it, so it keeps the
//  Keplerian element row from JPL's "Keplerian Elements for Approximate
//  Positions of the Major Planets" (E. M. Standish), a two-body fit valid for
//  1800-2050 and good to well under an arcminute over that span — see the
//  note on `Planet.pluto` and `PlutoTests`. It is reduced through the same
//  nutation and aberration as everything else, so it sits in the same frame.
//
//  Apparent magnitudes are from Mallama & Hilton, "Computing apparent
//  planetary magnitudes for The Astronomical Almanac", Astronomy and
//  Computing 25, 10 (2018) — the current Almanac formulae — with the classic
//  5 log₁₀(rΔ) distance term.
//

import Foundation
import simd

/// The bodies carried by the JPL Keplerian element table (Earth is handled
/// separately below, as the Earth-Moon barycentre).
///
/// Pluto is in the table as its ninth row and is included here for that
/// reason: it is the same source, fitted the same way, so its provenance is
/// consistent with everything else in this file. Two caveats belong with it:
/// it is the **least accurate** row in the table (a highly inclined,
/// eccentric orbit fitted by a purely two-body Keplerian solution, so the
/// residual is degrees rather than the few arcminutes the inner planets
/// enjoy), and the 1800-2050 validity window matters far more for it — one
/// Pluto orbit is 248 years, so the window is barely a single revolution and
/// the linear element rates have no long baseline to be right over.
enum Planet: String, CaseIterable, Identifiable {
    case mercury, venus, mars, jupiter, saturn, uranus, neptune, pluto
    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }

    /// Pluto is a dwarf planet (IAU 2006 resolution B5), not a major planet.
    /// It is classified honestly everywhere it is shown.
    var isDwarfPlanet: Bool { self == .pluto }

    /// The VSOP87 series for this body, or nil for Pluto, which the theory
    /// does not cover.
    var vsopBody: VSOP87.Body? {
        switch self {
        case .mercury: return .mercury
        case .venus: return .venus
        case .mars: return .mars
        case .jupiter: return .jupiter
        case .saturn: return .saturn
        case .uranus: return .uranus
        case .neptune: return .neptune
        case .pluto: return nil
        }
    }
}

/// Mean orbital elements at J2000.0 and their rates per Julian century.
/// Columns: a (AU), e, i (deg), L (mean longitude, deg), long. of perihelion (deg), long. of ascending node (deg).
private struct OrbitalElements {
    let a0: Double, aDot: Double
    let e0: Double, eDot: Double
    let i0: Double, iDot: Double
    let l0: Double, lDot: Double
    let peri0: Double, periDot: Double
    let node0: Double, nodeDot: Double
}

/// Keplerian elements are kept only for Pluto; see the file comment.
private let elementsTable: [Planet: OrbitalElements] = [
    // Ninth row of the same JPL table, valid 1800-2050. See the note on
    // `Planet` above: this is the least accurate entry in the set, and the
    // validity window is the binding constraint for it in a way it is not for
    // Mercury.
    .pluto: OrbitalElements(
        a0: 39.48211675, aDot: -0.00031596,
        e0: 0.24882730, eDot: 0.00005170,
        i0: 17.14001206, iDot: 0.00004818,
        l0: 238.92903833, lDot: 145.20780515,
        peri0: 224.06891629, periDot: -0.04062942,
        node0: 110.30393684, nodeDot: -0.01183482
    ),
]

/// Everything the renderer and the planner need about a planet at one
/// instant: where it is, how far away it is (so its disk can be sized
/// truthfully), how much of the disk the Sun lights up, and how bright it is.
struct PlanetState: Sendable {
    /// Apparent RA/Dec, true equator and equinox of date.
    let equatorial: EquatorialCoordinate
    /// Earth-planet distance, AU (light-time corrected). Drives the apparent
    /// angular diameter.
    let geocentricDistanceAU: Double
    /// Sun-planet distance, AU.
    let heliocentricDistanceAU: Double
    /// Illuminated fraction of the disk, 0 (new) ... 1 (full).
    let illuminatedFraction: Double
    /// Sun-planet-Earth angle, degrees.
    let phaseAngleDegrees: Double
    /// Sun-Earth-planet angle, degrees: how far from the Sun the planet
    /// appears in the sky.
    let elongationDegrees: Double
    /// Apparent visual magnitude.
    let magnitude: Double
    /// Geocentric ecliptic longitude and latitude of date, degrees, before
    /// nutation — what Saturn's ring geometry is expressed in.
    let eclipticLongitudeDegrees: Double
    let eclipticLatitudeDegrees: Double
}

enum PlanetPosition {

    /// Geocentric apparent RA/Dec for a planet at the given **UT** Julian Day.
    static func equatorialCoordinate(planet: Planet, julianDay jd: Double) -> EquatorialCoordinate {
        state(planet: planet, julianDay: jd).equatorial
    }

    /// Full geocentric state for a UT Julian Day.
    static func state(planet: Planet, julianDay jd: Double) -> PlanetState {
        state(planet: planet, earth: EarthState(julianDayUT: jd))
    }

    /// Full geocentric state, from an Earth already computed for the instant.
    static func state(planet: Planet, earth: EarthState) -> PlanetState {
        let tt = earth.julianDayTT
        let earthPosition = earth.position

        // Heliocentric position of the planet at the instant the light now
        // arriving left it. Two passes of the light-time iteration (Meeus
        // Ch. 33) converge to well under a millisecond of light-time for
        // every planet.
        var planetPosition = heliocentricEclipticOfDate(planet: planet, julianDayTT: tt)
        var geocentric = planetPosition - earthPosition
        var delta = simd_length(geocentric)
        for _ in 0..<2 {
            let lightTime = delta * EarthState.lightDaysPerAU
            planetPosition = heliocentricEclipticOfDate(planet: planet, julianDayTT: tt - lightTime)
            geocentric = planetPosition - earthPosition
            delta = simd_length(geocentric)
        }

        let r = simd_length(planetPosition)
        let bigR = simd_length(earthPosition)

        // Phase angle from the Sun-planet-Earth triangle (Meeus 41.2) and the
        // illuminated fraction k = (1 + cos i) / 2 (41.1).
        let denominator = 2 * r * delta
        let cosPhaseAngle = denominator > 1e-12
            ? max(-1.0, min(1.0, (r * r + delta * delta - bigR * bigR) / denominator))
            : 1.0
        let phaseAngle = Angle.radiansToDegrees(acos(cosPhaseAngle))
        let k = max(0.0, min(1.0, (1 + cosPhaseAngle) / 2))

        // Elongation from the Sun-Earth-planet triangle.
        let elongationDenominator = 2 * bigR * delta
        let cosElongation = elongationDenominator > 1e-12
            ? max(-1.0, min(1.0, (bigR * bigR + delta * delta - r * r) / elongationDenominator))
            : 1.0
        let elongation = Angle.radiansToDegrees(acos(cosElongation))

        let equatorial = earth.apparentEquatorial(geocentricEcliptic: geocentric)

        return PlanetState(
            equatorial: equatorial,
            geocentricDistanceAU: delta,
            heliocentricDistanceAU: r,
            illuminatedFraction: k,
            phaseAngleDegrees: phaseAngle,
            elongationDegrees: elongation,
            magnitude: PlanetMagnitude.apparentMagnitude(
                planet: planet, heliocentricDistanceAU: r, geocentricDistanceAU: delta,
                phaseAngleDegrees: phaseAngle,
                saturnRingTiltDegrees: planet == .saturn
                    ? SaturnRings.ringPlaneTiltDegrees(geocentricEclipticOfDate: geocentric, julianCenturiesTT: earth.julianCenturiesTT)
                    : 0
            ),
            eclipticLongitudeDegrees: Angle.normalizeDegrees(Angle.radiansToDegrees(atan2(geocentric.y, geocentric.x))),
            eclipticLatitudeDegrees: Angle.radiansToDegrees(
                atan2(geocentric.z, (geocentric.x * geocentric.x + geocentric.y * geocentric.y).squareRoot())
            )
        )
    }

    /// Heliocentric rectangular position in the ecliptic and equinox of date,
    /// AU, for a TT Julian Day.
    ///
    /// VSOP87D for the eight planets. Pluto's Keplerian elements are J2000, so
    /// its vector is precessed to the date here (ecliptic precession, Meeus
    /// Ch. 21) to land in the same frame; the operation is a rotation by the
    /// general precession in longitude, since the ecliptic's own tilt changes
    /// by well under an arcminute over the window.
    static func heliocentricEclipticOfDate(planet: Planet, julianDayTT tt: Double) -> SIMD3<Double> {
        if let body = planet.vsopBody {
            return VSOP87.heliocentricRectangular(body, julianDayTT: tt)
        }
        let t = JulianDate.julianCenturies(fromJulianDay: tt)
        let j2000 = heliocentricEclipticPosition(elements: elementsTable[planet]!, t: t)
        // Precess J2000 ecliptic -> ecliptic of date through the equatorial
        // frame, using the same rotation the catalogues use, so the two
        // agree by construction.
        let toEquatorialJ2000 = Nutation.eclipticToEquatorial(obliquityDegrees: 23.4392911)
        let precession = Precession.rotationMatrix(julianDay: tt)
        let toEclipticOfDate = Nutation.eclipticToEquatorial(
            obliquityDegrees: Nutation.meanObliquityDegrees(julianCenturies: t)
        ).transpose
        let v = toEclipticOfDate * precession * toEquatorialJ2000 * SIMD3(j2000.x, j2000.y, j2000.z)
        return v
    }

    /// Solves Kepler's equation and returns the heliocentric ecliptic
    /// rectangular coordinates (AU) for the given mean orbital elements at
    /// time `t` (Julian centuries since J2000.0).
    private static func heliocentricEclipticPosition(elements el: OrbitalElements, t: Double) -> (x: Double, y: Double, z: Double) {
        let a = el.a0 + el.aDot * t
        let e = el.e0 + el.eDot * t
        let i = Angle.degreesToRadians(el.i0 + el.iDot * t)
        let l = Angle.degreesToRadians(Angle.normalizeDegrees(el.l0 + el.lDot * t))
        let peri = Angle.degreesToRadians(Angle.normalizeDegrees(el.peri0 + el.periDot * t))
        let node = Angle.degreesToRadians(Angle.normalizeDegrees(el.node0 + el.nodeDot * t))

        let meanAnomaly = l - peri
        let argPerihelion = peri - node

        // Solve Kepler's equation M = E - e sin E via Newton-Raphson.
        var eAnomaly = meanAnomaly
        for _ in 0..<10 {
            let delta = (eAnomaly - e * sin(eAnomaly) - meanAnomaly) / (1 - e * cos(eAnomaly))
            eAnomaly -= delta
            if abs(delta) < 1e-10 { break }
        }

        // Position in the orbital plane.
        let xOrbit = a * (cos(eAnomaly) - e)
        let yOrbit = a * sqrt(1 - e * e) * sin(eAnomaly)

        // Rotate by argument of perihelion, inclination, and node into the
        // ecliptic (J2000) frame.
        let cosNode = cos(node), sinNode = sin(node)
        let cosPeri = cos(argPerihelion), sinPeri = sin(argPerihelion)
        let cosI = cos(i), sinI = sin(i)

        let xTemp = cosPeri * xOrbit - sinPeri * yOrbit
        let yTemp = sinPeri * xOrbit + cosPeri * yOrbit

        let x = (cosNode * xTemp - sinNode * yTemp * cosI)
        let y = (sinNode * xTemp + cosNode * yTemp * cosI)
        let z = yTemp * sinI

        return (x, y, z)
    }
}
