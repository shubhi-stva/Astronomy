//
//  PlanetPosition.swift
//  Astronomy
//
//  Low-precision planetary positions using mean Keplerian orbital elements
//  and their secular (linear-in-time) rates, valid for the years 1800-2050.
//
//  Reference: "Keplerian Elements for Approximate Positions of the Major
//  Planets" by E.M. Standish (JPL/Solar System Dynamics Group), the same
//  low-precision element set summarized in Meeus's "Astronomical
//  Algorithms" Chapter 31 ("Elements of Planetary Orbits"). Two-body
//  Keplerian motion only (no planetary perturbations), giving accuracy on
//  the order of a few arcminutes for the inner planets and somewhat worse
//  for the outer planets — adequate for sky-chart visualization.
//

import Foundation

enum Planet: String, CaseIterable, Identifiable {
    case mercury, venus, mars, jupiter, saturn, uranus, neptune
    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
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

private let elementsTable: [Planet: OrbitalElements] = [
    .mercury: OrbitalElements(
        a0: 0.38709927, aDot: 0.00000037,
        e0: 0.20563593, eDot: 0.00001906,
        i0: 7.00497902, iDot: -0.00594749,
        l0: 252.25032350, lDot: 149472.67411175,
        peri0: 77.45779628, periDot: 0.16047689,
        node0: 48.33076593, nodeDot: -0.12534081
    ),
    .venus: OrbitalElements(
        a0: 0.72333566, aDot: 0.00000390,
        e0: 0.00677672, eDot: -0.00004107,
        i0: 3.39467605, iDot: -0.00078890,
        l0: 181.97909950, lDot: 58517.81538729,
        peri0: 131.60246718, periDot: 0.00268329,
        node0: 76.67984255, nodeDot: -0.27769418
    ),
    .mars: OrbitalElements(
        a0: 1.52371034, aDot: 0.00001847,
        e0: 0.09339410, eDot: 0.00007882,
        i0: 1.84969142, iDot: -0.00813131,
        l0: -4.55343205, lDot: 19140.30268499,
        peri0: -23.94362959, periDot: 0.44441088,
        node0: 49.55953891, nodeDot: -0.29257343
    ),
    .jupiter: OrbitalElements(
        a0: 5.20288700, aDot: -0.00011607,
        e0: 0.04838624, eDot: -0.00013253,
        i0: 1.30439695, iDot: -0.00183714,
        l0: 34.39644051, lDot: 3034.74612775,
        peri0: 14.72847983, periDot: 0.21252668,
        node0: 100.47390909, nodeDot: 0.20469106
    ),
    .saturn: OrbitalElements(
        a0: 9.53667594, aDot: -0.00125060,
        e0: 0.05386179, eDot: -0.00050991,
        i0: 2.48599187, iDot: 0.00193609,
        l0: 49.95424423, lDot: 1222.49362201,
        peri0: 92.59887831, periDot: -0.41897216,
        node0: 113.66242448, nodeDot: -0.28867794
    ),
    .uranus: OrbitalElements(
        a0: 19.18916464, aDot: -0.00196176,
        e0: 0.04725744, eDot: -0.00004397,
        i0: 0.77263783, iDot: -0.00242939,
        l0: 313.23810451, lDot: 428.48202785,
        peri0: 170.95427630, periDot: 0.40805281,
        node0: 74.01692503, nodeDot: 0.04240589
    ),
    .neptune: OrbitalElements(
        a0: 30.06992276, aDot: 0.00026291,
        e0: 0.00859048, eDot: 0.00005105,
        i0: 1.77004347, iDot: 0.00035372,
        l0: -55.12002969, lDot: 218.45945325,
        peri0: 44.96476227, periDot: -0.32241464,
        node0: 131.78422574, nodeDot: -0.00508664
    ),
]

// Earth-Moon barycenter elements, needed to compute Earth's heliocentric
// position for the geocentric correction of other planets.
private let earthElements = OrbitalElements(
    a0: 1.00000261, aDot: 0.00000562,
    e0: 0.01671123, eDot: -0.00004392,
    i0: -0.00001531, iDot: -0.01294668,
    l0: 100.46457166, lDot: 35999.37244981,
    peri0: 102.93768193, periDot: 0.32327364,
    node0: 0.0, nodeDot: 0.0
)

enum PlanetPosition {

    /// Geocentric apparent RA/Dec for a planet at the given Julian Day.
    static func equatorialCoordinate(planet: Planet, julianDay jd: Double) -> EquatorialCoordinate {
        let t = JulianDate.julianCenturies(fromJulianDay: jd)

        let earthHelio = heliocentricEclipticPosition(elements: earthElements, t: t)
        let planetHelio = heliocentricEclipticPosition(elements: elementsTable[planet]!, t: t)

        // Geocentric ecliptic vector = planet heliocentric - Earth heliocentric.
        let gx = planetHelio.x - earthHelio.x
        let gy = planetHelio.y - earthHelio.y
        let gz = planetHelio.z - earthHelio.z

        // Obliquity of the ecliptic (mean, of date).
        let meanObliquity = 23.439291 - 0.0130042 * t
        let epsilon = Angle.degreesToRadians(meanObliquity)

        // Rotate ecliptic -> equatorial.
        let xEq = gx
        let yEq = gy * cos(epsilon) - gz * sin(epsilon)
        let zEq = gy * sin(epsilon) + gz * cos(epsilon)

        let raRad = atan2(yEq, xEq)
        let decRad = atan2(zEq, sqrt(xEq * xEq + yEq * yEq))

        return EquatorialCoordinate(
            rightAscensionDegrees: Angle.normalizeDegrees(Angle.radiansToDegrees(raRad)),
            declinationDegrees: Angle.radiansToDegrees(decRad)
        )
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
