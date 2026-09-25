//
//  JupiterMoons.swift
//  Astronomy
//
//  Positions of the four Galilean satellites relative to Jupiter.
//
//  Reference: Jean Meeus, "Astronomical Algorithms", 2nd ed., Chapter 44,
//  the "lower accuracy" method: circular orbits in Jupiter's equatorial plane
//  with the principal perturbation terms, Jupiter itself from a short
//  ecliptic series and the light-time to Jupiter taken out of the satellite
//  phases. Meeus quotes it as good to about 0.1 Jupiter radii — a few
//  arcseconds — which is well under a pixel until the disk is a hundred
//  pixels across, at which point it is a couple of pixels on moons drawn
//  as three-pixel dots.
//
//  The output is the apparent offset of each moon from Jupiter's centre in
//  units of Jupiter's equatorial radius: X positive toward the *west*
//  (decreasing right ascension), Y positive toward the north, as Meeus
//  defines them. Z is the distance along the line of sight, positive when the
//  moon is *behind* Jupiter, so a moon at |X| < 1, |Y| < 1 with Z > 0 is
//  occulted and one with Z < 0 is in transit. Eclipses in Jupiter's shadow
//  are not modelled; a moon in eclipse is drawn where it is, invisibly dim.
//
//  Verified against JPL Horizons in `AccuracyTests`.
//

import Foundation

enum JupiterMoons {

    enum Moon: Int, CaseIterable, Identifiable, Sendable {
        case io = 1, europa, ganymede, callisto
        var id: Int { rawValue }
        var name: String {
            switch self {
            case .io: return "Io"
            case .europa: return "Europa"
            case .ganymede: return "Ganymede"
            case .callisto: return "Callisto"
            }
        }
        /// Object identifier used for selection and labels.
        var objectID: String { "jupiter-moon-\(name.lowercased())" }
        /// Mean apparent visual magnitude at opposition (Astronomical Almanac).
        var magnitude: Double {
            switch self {
            case .io: return 5.0
            case .europa: return 5.3
            case .ganymede: return 4.6
            case .callisto: return 5.7
            }
        }
        /// Mean radius, km (NASA fact sheet), for the info panel.
        var radiusKm: Double {
            switch self {
            case .io: return 1821.6
            case .europa: return 1560.8
            case .ganymede: return 2634.1
            case .callisto: return 2410.3
            }
        }
    }

    struct Position: Hashable, Sendable {
        let moon: Moon
        /// Offsets in Jupiter equatorial radii: X west-positive, Y north-positive.
        let x: Double
        let y: Double
        /// Line-of-sight ordering: positive behind Jupiter.
        let z: Double
        /// Angular distance from Jupiter's centre, degrees, for a Jupiter
        /// disk of the given apparent radius.
        func offsetDegrees(jupiterRadiusDegrees: Double) -> (west: Double, north: Double) {
            (x * jupiterRadiusDegrees, y * jupiterRadiusDegrees)
        }
        /// Hidden behind the planet's disk.
        var isOcculted: Bool { z > 0 && x * x + y * y < 1 }
        /// In front of the planet's disk.
        var isInTransit: Bool { z < 0 && x * x + y * y < 1 }
    }

    /// Jupiter's equatorial radius, km (IAU 2015).
    static let jupiterEquatorialRadiusKm = 71_492.0

    /// The four moons at a **UT** Julian Day.
    static func positions(julianDay jdUT: Double) -> [Position] {
        let jde = DeltaT.terrestrialJulianDay(fromUniversal: jdUT)
        let d = jde - 2_451_545.0
        let rad = Double.pi / 180.0
        func sinD(_ x: Double) -> Double { sin(x * rad) }
        func cosD(_ x: Double) -> Double { cos(x * rad) }

        // Jupiter and the Earth (Meeus 44, "lower accuracy").
        let v = 172.74 + 0.00111588 * d
        let m = 357.529 + 0.9856003 * d
        let n = 20.020 + 0.0830853 * d + 0.329 * sinD(v)
        let j = 66.115 + 0.9025179 * d - 0.329 * sinD(v)
        let a = 1.915 * sinD(m) + 0.020 * sinD(2 * m)
        let b = 5.555 * sinD(n) + 0.168 * sinD(2 * n)
        let k = j + a - b
        let bigR = 1.00014 - 0.01671 * cosD(m) - 0.00014 * cosD(2 * m)
        let r = 5.20872 - 0.25208 * cosD(n) - 0.00611 * cosD(2 * n)
        let delta = (r * r + bigR * bigR - 2 * r * bigR * cosD(k)).squareRoot()
        let psi = asin(max(-1, min(1, bigR / delta * sinD(k)))) / rad
        let lambda = 34.35 + 0.083091 * d + 0.329 * sinD(v) + b
        let dS = 3.12 * sinD(lambda + 42.8)
        let dE = dS - 2.22 * sinD(psi) * cosD(lambda + 22)
            - 1.30 * (r - delta) / delta * sinD(lambda - 100.5)

        // Light-time corrected phases.
        let t = d - delta / 173.0
        var u1 = 163.8069 + 203.4058646 * t + psi - b
        var u2 = 358.4140 + 101.2916335 * t + psi - b
        var u3 = 5.7176 + 50.2345180 * t + psi - b
        var u4 = 224.8092 + 21.4879800 * t + psi - b
        let g = 331.18 + 50.310482 * t
        let h = 87.40 + 21.569231 * t

        let c1 = 0.473 * sinD(2 * (u1 - u2))
        let c2 = 1.065 * sinD(2 * (u2 - u3))
        let c3 = 0.165 * sinD(g)
        let c4 = 0.841 * sinD(h)
        u1 += c1; u2 += c2; u3 += c3; u4 += c4

        let r1 = 5.9057 - 0.0244 * cosD(2 * (u1 - u2))
        let r2 = 9.3966 - 0.0882 * cosD(2 * (u2 - u3))
        let r3 = 14.9883 - 0.0216 * cosD(g)
        let r4 = 26.3627 - 0.1939 * cosD(h)

        func position(_ moon: Moon, u: Double, radius: Double) -> Position {
            Position(
                moon: moon,
                x: radius * sinD(u),
                y: -radius * cosD(u) * sinD(dE),
                z: radius * cosD(u) * cosD(dE)
            )
        }
        return [
            position(.io, u: u1, radius: r1),
            position(.europa, u: u2, radius: r2),
            position(.ganymede, u: u3, radius: r3),
            position(.callisto, u: u4, radius: r4),
        ]
    }

    /// The offset on the sky, in Jupiter radii, west- and north-positive.
    ///
    /// The model's X/Y are in Jupiter's own equatorial frame; the planet's
    /// north pole is tilted on the sky by its position angle P (east of
    /// north), so the frame is rotated by P to land in RA/Dec.
    static func skyOffset(
        of position: Position, polePositionAngleDegrees p: Double
    ) -> (west: Double, north: Double) {
        let c = cos(Angle.degreesToRadians(p)), s = sin(Angle.degreesToRadians(p))
        return (position.x * c - position.y * s, position.x * s + position.y * c)
    }

    /// Apparent equatorial place of a moon given Jupiter's, for selection and
    /// the info panel.
    static func equatorial(
        of position: Position, jupiter: EquatorialCoordinate, jupiterDistanceKm: Double,
        polePositionAngleDegrees: Double
    ) -> EquatorialCoordinate {
        let radiusDegrees = Angle.radiansToDegrees(atan(jupiterEquatorialRadiusKm / jupiterDistanceKm))
        let offset = skyOffset(of: position, polePositionAngleDegrees: polePositionAngleDegrees)
        let (west, north) = (offset.west * radiusDegrees, offset.north * radiusDegrees)
        let cosDec = max(0.01, cos(Angle.degreesToRadians(jupiter.declinationDegrees)))
        return EquatorialCoordinate(
            rightAscensionDegrees: Angle.normalizeDegrees(jupiter.rightAscensionDegrees - west / cosDec),
            declinationDegrees: jupiter.declinationDegrees + north
        )
    }
}
