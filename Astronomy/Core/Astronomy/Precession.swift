//
//  Precession.swift
//  Astronomy
//
//  Precession of the equinoxes: catalogue J2000.0 mean places -> mean place
//  of the displayed date.
//
//  WHY THIS EXISTS
//
//  The bundled star and deep-sky catalogues give RA/Dec referred to the mean
//  equinox and equator of J2000.0. The Earth's axis moves: the equinox
//  regresses along the ecliptic at about 50.29 arcseconds a year, so a
//  catalogue position is not where the object is *now* relative to the
//  observer's celestial equator. By 2026 that is already ~0.36 degrees — a
//  visible offset at any field narrower than a few degrees, and about
//  two-thirds of a Moon diameter. A time machine that spans decades makes it
//  far worse: at 2100 it is ~1.4 degrees, and the app would be confidently
//  drawing the wrong sky.
//
//  Note the Sun, Moon and planets are *not* precessed here. Their series
//  (Meeus Ch. 25 for the Sun, Ch. 47 for the Moon) already produce positions
//  referred to the equinox of date; the JPL Keplerian planet elements do not,
//  which is why `PlanetPosition` applies this rotation itself.
//
//  FORMULATION
//
//  IAU 1976 precession (Lieske, Lederle, Fricke & Morando, Astron. Astrophys.
//  58, 1 (1977)), in the rigorous three-angle form given by Jean Meeus,
//  "Astronomical Algorithms", 2nd ed., Chapter 21, equations 21.2 and 21.4,
//  reduced to the fixed starting epoch J2000.0 (so Meeus's T = 0 and his
//  t equals the interval from J2000 in Julian centuries).
//
//      zeta  = 2306.2181 t + 0.30188 t^2 + 0.017998 t^3   (arcseconds)
//      z     = 2306.2181 t + 1.09468 t^2 + 0.018203 t^3
//      theta = 2004.3109 t - 0.42665 t^2 - 0.041833 t^3
//
//  The rotation is then R_z(-z) . R_y(theta) . R_z(-zeta), applied to the unit
//  vector of the J2000 position. Meeus writes the same thing out in
//  trigonometric form (21.4); the matrix is used here because the whole frame
//  shares one epoch, so the nine coefficients are computed once and every star
//  costs a single matrix-vector product instead of its own trigonometry.
//
//  WHAT IS DELIBERATELY NOT MODELLED
//
//  * **Proper motion.** The catalogue carries no per-star velocity, so stars
//    are treated as fixed on the celestial sphere. This is the largest
//    remaining error for a long time span: Barnard's Star moves 10.3
//    arcseconds a year and Arcturus 2.3, so a century-scale jump misplaces
//    the fastest movers by arcminutes. Every naked-eye star stays well within
//    a pixel at any field this app draws over a few decades.
//  * **Nutation** (up to 17 arcseconds in longitude, 9 in obliquity) and
//    **aberration** (up to 20 arcseconds). Both are an order of magnitude
//    below one pixel at any field of view the app offers.
//  * The IAU 2006/P03 refinement. It differs from IAU 1976 by well under an
//    arcsecond across the 1800-2050 window this app is honest about, which is
//    far below anything visible here.
//

import Foundation
import simd

enum Precession {

    /// The three IAU 1976 precession angles from J2000.0 to `julianDay`, in
    /// degrees. Meeus (2nd ed.) eq. 21.2 with T = 0.
    ///
    /// Returned in degrees rather than the arcseconds of the source because
    /// every other angle in this codebase is in degrees, and mixing units is
    /// how sign errors hide.
    static func anglesDegrees(julianDay jd: Double) -> (zeta: Double, z: Double, theta: Double) {
        let t = JulianDate.julianCenturies(fromJulianDay: jd)
        let t2 = t * t
        let t3 = t2 * t
        let arcsecondsToDegrees = 1.0 / 3600.0
        return (
            zeta: (2306.2181 * t + 0.30188 * t2 + 0.017998 * t3) * arcsecondsToDegrees,
            z: (2306.2181 * t + 1.09468 * t2 + 0.018203 * t3) * arcsecondsToDegrees,
            theta: (2004.3109 * t - 0.42665 * t2 - 0.041833 * t3) * arcsecondsToDegrees
        )
    }

    /// Rotation taking a J2000.0 mean equatorial unit vector to the mean
    /// equatorial frame of `julianDay`.
    ///
    /// This is the matrix form of Meeus 21.4. It is built once per frame and
    /// shared by every catalogue object, which is the only reason precessing
    /// tens of thousands of stars per frame is affordable.
    static func rotationMatrix(julianDay jd: Double) -> simd_double3x3 {
        let a = anglesDegrees(julianDay: jd)
        let zeta = Angle.degreesToRadians(a.zeta)
        let z = Angle.degreesToRadians(a.z)
        let theta = Angle.degreesToRadians(a.theta)

        let cz = cos(zeta), sz = sin(zeta)
        let cZ = cos(z), sZ = sin(z)
        let ct = cos(theta), st = sin(theta)

        // R = Rz(-z) . Ry(theta) . Rz(-zeta), written out. Rows below are the
        // rows of R; simd_double3x3 takes *columns*, so the initialiser is
        // transposed relative to how the coefficients read.
        let r00 = cz * ct * cZ - sz * sZ
        let r01 = -sz * ct * cZ - cz * sZ
        let r02 = -st * cZ
        let r10 = cz * ct * sZ + sz * cZ
        let r11 = -sz * ct * sZ + cz * cZ
        let r12 = -st * sZ
        let r20 = cz * st
        let r21 = -sz * st
        let r22 = ct

        return simd_double3x3(
            SIMD3(r00, r10, r20),
            SIMD3(r01, r11, r21),
            SIMD3(r02, r12, r22)
        )
    }

    /// The identity: no precession at all. Used by frames built before an
    /// epoch is known, and by tests that want the untouched catalogue frame.
    static let identity = simd_double3x3(1.0)

    /// Unit vector for an equatorial coordinate.
    static func unitVector(_ equatorial: EquatorialCoordinate) -> SIMD3<Double> {
        let ra = Angle.degreesToRadians(equatorial.rightAscensionDegrees)
        let dec = Angle.degreesToRadians(equatorial.declinationDegrees)
        let cosDec = cos(dec)
        return SIMD3(cosDec * cos(ra), cosDec * sin(ra), sin(dec))
    }

    /// Equatorial coordinate for a (not necessarily normalised) vector.
    static func equatorial(fromVector v: SIMD3<Double>) -> EquatorialCoordinate {
        let ra = Angle.radiansToDegrees(atan2(v.y, v.x))
        let dec = Angle.radiansToDegrees(atan2(v.z, (v.x * v.x + v.y * v.y).squareRoot()))
        return EquatorialCoordinate(
            rightAscensionDegrees: Angle.normalizeDegrees(ra),
            declinationDegrees: dec
        )
    }

    /// Applies a precomputed precession rotation to a J2000 catalogue position.
    static func precess(_ equatorial: EquatorialCoordinate, matrix: simd_double3x3) -> EquatorialCoordinate {
        Self.equatorial(fromVector: matrix * unitVector(equatorial))
    }

    /// Convenience for one-off use (search, tests). Builds the matrix each
    /// call, so never use it inside a per-object loop.
    static func precess(_ equatorial: EquatorialCoordinate, julianDay jd: Double) -> EquatorialCoordinate {
        precess(equatorial, matrix: rotationMatrix(julianDay: jd))
    }
}
