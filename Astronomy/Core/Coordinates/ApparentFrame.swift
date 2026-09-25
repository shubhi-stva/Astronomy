//
//  ApparentFrame.swift
//  Astronomy
//
//  The reduction from a catalogue or ephemeris direction to the *apparent*
//  direction an observer on the moving Earth actually sees at one instant.
//
//  Two objects live here.
//
//  `EarthState` is where the Earth is and how fast it is moving, plus the
//  nutation angles, for one instant. Every solar-system ephemeris in this app
//  starts from it: the Sun is simply the Earth's heliocentric position
//  negated; a planet is its own heliocentric position minus the Earth's, with
//  the light-time iteration; the Moon's geocentric series needs only the
//  nutation. Building the state once and handing it to all of them is both
//  cheaper and — more importantly — guarantees every body in a frame is
//  reduced with the *same* Earth, so no two of them can disagree about the
//  frame they are drawn in.
//
//  `ApparentFrame` is the same information packaged for the *catalogue*:
//  one rotation (precession then nutation, J2000 -> true equator and equinox
//  of date), one vector (annual aberration) and one angle (apparent sidereal
//  time). `SkyProjector` folds the rotation into its per-frame matrix and
//  applies the vector per star, so tens of thousands of stars are reduced for
//  the price of a matrix product and a vector add each.
//
//  What the reduction includes, and the size of each effect in 2026:
//
//   * precession, 0.36° and growing — `Precession`;
//   * nutation, up to 17" — `Nutation`;
//   * annual aberration, up to 20.5" — here, as the classical first-order
//     displacement `v' = normalize(v + V/c)` toward the apex of the Earth's
//     motion, which is how Meeus's Ch. 23 formulae are derived and is exact to
//     0.001" for the purpose;
//   * light-time for the planets — `PlanetPosition`;
//   * the FK5 frame correction for VSOP87's dynamical ecliptic, 0.1" — here;
//   * ΔT, 69 s, the one that makes the Moon 35" different — `DeltaT`.
//
//  What it deliberately leaves out: proper motion (no catalogue velocities),
//  stellar parallax (< 0.8"), gravitational light deflection (1.7" at the
//  Sun's limb, < 0.02" more than 10° from it), polar motion (0.3"), diurnal
//  aberration (0.3"). Every one of these is under a quarter of a pixel at the
//  narrowest field the app draws.
//

import Foundation
import simd

/// The Earth at one instant, and the nutation of that instant.
struct EarthState: Sendable {
    /// Speed of light in AU per day (IAU 2012 AU, CODATA c).
    static let lightSpeedAUPerDay = 173.144_632_674

    /// Light-time in days per AU of distance.
    static let lightDaysPerAU = 1.0 / lightSpeedAUPerDay

    let julianDayUT: Double
    let julianDayTT: Double
    let nutation: Nutation.Angles

    /// Heliocentric position of the Earth, ecliptic and equinox of date, AU.
    let heliocentric: VSOP87.Spherical
    /// The same, rectangular.
    let position: SIMD3<Double>
    /// Earth's heliocentric velocity divided by the speed of light, ecliptic
    /// of date. Its magnitude is the constant of aberration, ~20.5".
    let velocityOverLight: SIMD3<Double>

    /// Ecliptic of date -> **true** equator and equinox of date.
    let eclipticToEquatorial: simd_double3x3
    /// The aberration displacement vector in the true equatorial frame of
    /// date: the thing to add to a geocentric unit direction before
    /// renormalising.
    let aberration: SIMD3<Double>

    /// - Parameter julianDayUT: the instant as a UT Julian Day (i.e. straight
    ///   from a `Date`). TT is derived here; callers never convert.
    init(julianDayUT: Double) {
        self.julianDayUT = julianDayUT
        let tt = DeltaT.terrestrialJulianDay(fromUniversal: julianDayUT)
        julianDayTT = tt
        nutation = Nutation.angles(julianDayTT: tt)
        heliocentric = VSOP87.heliocentric(.earth, julianDayTT: tt)
        position = heliocentric.rectangular

        // Velocity by central difference over a tenth of a day. The series is
        // smooth and the step is a thousandth of an orbit, so the truncation
        // error is far below the constant of aberration's own uncertainty.
        let h = 0.05
        let ahead = VSOP87.heliocentricRectangular(.earth, julianDayTT: tt + h)
        let behind = VSOP87.heliocentricRectangular(.earth, julianDayTT: tt - h)
        velocityOverLight = (ahead - behind) / (2 * h) / Self.lightSpeedAUPerDay

        eclipticToEquatorial = Nutation.eclipticToEquatorial(
            obliquityDegrees: nutation.trueObliquityDegrees
        )
        aberration = eclipticToEquatorial * velocityOverLight
    }

    // MARK: - Reductions

    /// Julian centuries (TT) from J2000.0.
    var julianCenturiesTT: Double { JulianDate.julianCenturies(fromJulianDay: julianDayTT) }

    /// Reduces a **geocentric** direction expressed in the dynamical ecliptic
    /// of date (as VSOP87 delivers it, after any light-time correction) to an
    /// apparent RA/Dec referred to the true equator and equinox of date.
    ///
    /// Steps, in Meeus's order (Ch. 33): FK5 correction (32.3), nutation in
    /// longitude, conversion to equatorial with the true obliquity, aberration.
    func apparentEquatorial(
        geocentricEcliptic g: SIMD3<Double>, applyAberration: Bool = true
    ) -> EquatorialCoordinate {
        Precession.equatorial(fromVector: apparentEquatorialVector(
            geocentricEcliptic: g, applyAberration: applyAberration
        ))
    }

    /// The unit vector form of `apparentEquatorial`.
    func apparentEquatorialVector(
        geocentricEcliptic g: SIMD3<Double>, applyAberration: Bool = true
    ) -> SIMD3<Double> {
        var longitude = atan2(g.y, g.x)
        let latitude = atan2(g.z, (g.x * g.x + g.y * g.y).squareRoot())

        // FK5 correction, Meeus 32.3: the dynamical ecliptic VSOP87 uses is
        // not quite the FK5 one the catalogues (and hence precession) are in.
        let t = julianCenturiesTT
        let lambdaPrime = longitude - Angle.degreesToRadians(1.397 * t + 0.00031 * t * t)
        let arcsec = Double.pi / 648_000.0
        let deltaLongitude = (-0.09033 + 0.03916 * (cos(lambdaPrime) + sin(lambdaPrime)) * tan(latitude)) * arcsec
        let deltaLatitude = 0.03916 * (cos(lambdaPrime) - sin(lambdaPrime)) * arcsec
        longitude += deltaLongitude
        let correctedLatitude = latitude + deltaLatitude

        // Nutation in longitude, then to the true equator.
        longitude += Angle.degreesToRadians(nutation.deltaPsiDegrees)
        let cb = cos(correctedLatitude)
        let ecliptic = SIMD3(cb * cos(longitude), cb * sin(longitude), sin(correctedLatitude))
        var equatorial = eclipticToEquatorial * ecliptic

        if applyAberration {
            equatorial = simd_normalize(equatorial + aberration)
        }
        return equatorial
    }
}

/// The catalogue-side reduction for one instant. See the file comment.
struct ApparentFrame: Sendable {
    let earth: EarthState
    /// J2000 mean equatorial -> true equatorial of date (precession, then
    /// nutation).
    let j2000ToTrueOfDate: simd_double3x3
    /// Annual aberration displacement, true equatorial frame of date.
    let aberration: SIMD3<Double>
    /// Greenwich **apparent** sidereal time, degrees.
    let greenwichApparentSiderealDegrees: Double

    init(julianDayUT: Double) {
        self.init(earth: EarthState(julianDayUT: julianDayUT))
    }

    init(earth: EarthState) {
        self.earth = earth
        // Precession is a function of TT; the difference from evaluating it at
        // UT is 0.0001", so either would do — TT is simply the correct one.
        let precession = Precession.rotationMatrix(julianDay: earth.julianDayTT)
        let nutation = Nutation.rotationMatrix(angles: earth.nutation)
        j2000ToTrueOfDate = nutation * precession
        aberration = earth.aberration
        greenwichApparentSiderealDegrees = Angle.normalizeDegrees(
            CoordinateTransformService.greenwichMeanSiderealTimeDegrees(julianDay: earth.julianDayUT)
                + earth.nutation.equationOfEquinoxesDegrees
        )
    }

    /// Apparent direction (true equatorial of date, unit) for a J2000
    /// catalogue unit vector.
    @inline(__always)
    func apparentDirection(j2000Unit v: SIMD3<Double>) -> SIMD3<Double> {
        simd_normalize(j2000ToTrueOfDate * v + aberration)
    }

    /// Apparent RA/Dec of date for a J2000 catalogue position. The one-off
    /// form for search, fly-to and the info panel; the renderer uses the
    /// matrix and vector directly.
    func apparent(j2000 equatorial: EquatorialCoordinate) -> EquatorialCoordinate {
        Precession.equatorial(fromVector: apparentDirection(j2000Unit: Precession.unitVector(equatorial)))
    }

    /// Convenience for one-off callers that have only a Julian Day.
    static func apparent(j2000 equatorial: EquatorialCoordinate, julianDayUT: Double) -> EquatorialCoordinate {
        ApparentFrame(julianDayUT: julianDayUT).apparent(j2000: equatorial)
    }
}
