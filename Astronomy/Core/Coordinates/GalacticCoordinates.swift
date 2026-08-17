//
//  GalacticCoordinates.swift
//  Astronomy
//
//  Equatorial (J2000) -> Galactic coordinate rotation, used by the Milky Way
//  background layer to work out how far a given screen pixel lies from the
//  galactic equator.
//
//  Uses the IAU 1958 galactic coordinate system, expressed in J2000 equatorial
//  coordinates (the standard values quoted in e.g. the Hipparcos/Tycho
//  catalogue introduction, ESA SP-1200, Vol. 1, Sect. 1.5.3):
//
//      North galactic pole:  RA = 192.85948 deg,  Dec = +27.12825 deg
//      Galactic centre:      RA = 266.40510 deg,  Dec = -28.93617 deg
//
//  The rotation is built directly from those two directions, so no
//  hand-tuned constants are involved.
//

import Foundation
import simd

enum GalacticCoordinates {

    static let northPoleRADegrees = 192.85948
    static let northPoleDecDegrees = 27.12825
    static let centerRADegrees = 266.40510
    static let centerDecDegrees = -28.93617

    /// Unit vector in the equatorial Cartesian frame
    /// (X toward RA 0/Dec 0, Y toward RA 90/Dec 0, Z toward the north
    /// celestial pole) for a given RA/Dec in degrees.
    static func equatorialUnitVector(raDegrees: Double, decDegrees: Double) -> SIMD3<Double> {
        let ra = Angle.degreesToRadians(raDegrees)
        let dec = Angle.degreesToRadians(decDegrees)
        return SIMD3(cos(dec) * cos(ra), cos(dec) * sin(ra), sin(dec))
    }

    /// Rotation taking an equatorial unit vector to galactic Cartesian
    /// coordinates: X toward the galactic centre (l = 0, b = 0), Z toward the
    /// north galactic pole, Y completing the right-handed triad
    /// (l = 90 deg, b = 0).
    ///
    /// Applying it as `M * v` gives `(x, y, z)` with
    /// `sin(b) = z` and `l = atan2(y, x)`.
    static let equatorialToGalactic: simd_double3x3 = {
        let pole = equatorialUnitVector(raDegrees: northPoleRADegrees, decDegrees: northPoleDecDegrees)
        let rawCenter = equatorialUnitVector(raDegrees: centerRADegrees, decDegrees: centerDecDegrees)

        let gz = simd_normalize(pole)
        // Re-orthogonalise the centre direction against the pole so the basis
        // is exactly orthonormal despite the two catalogue values being
        // independently rounded.
        let gx = simd_normalize(rawCenter - gz * simd_dot(gz, rawCenter))
        let gy = simd_cross(gz, gx)

        // Rows are the galactic axes expressed in equatorial coordinates, so
        // that M * v projects v onto each axis.
        return simd_double3x3(rows: [gx, gy, gz])
    }()

    /// Galactic latitude `b` in degrees for an equatorial coordinate.
    static func galacticLatitudeDegrees(_ equatorial: EquatorialCoordinate) -> Double {
        let v = equatorialUnitVector(
            raDegrees: equatorial.rightAscensionDegrees,
            decDegrees: equatorial.declinationDegrees
        )
        let g = equatorialToGalactic * v
        return Angle.radiansToDegrees(asin(min(1.0, max(-1.0, g.z))))
    }

    /// Galactic longitude `l` in degrees (0...360) for an equatorial coordinate.
    static func galacticLongitudeDegrees(_ equatorial: EquatorialCoordinate) -> Double {
        let v = equatorialUnitVector(
            raDegrees: equatorial.rightAscensionDegrees,
            decDegrees: equatorial.declinationDegrees
        )
        let g = equatorialToGalactic * v
        return Angle.normalizeDegrees(Angle.radiansToDegrees(atan2(g.y, g.x)))
    }
}
