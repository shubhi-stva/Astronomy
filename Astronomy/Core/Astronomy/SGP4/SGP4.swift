//
//  SGP4.swift
//  Astronomy
//
//  A faithful Swift port of the public-domain SGP4/SDP4 reference
//  implementation.
//
//  Source: David Vallado's `SGP4.cpp` (version 2020-07-13), distributed with
//  Vallado, Crawford, Hujsak & Kelso, "Revisiting Spacetrack Report #3",
//  AIAA 2006-6753, and descended from Hoots & Roehrich, Spacetrack Report
//  No. 3 (1980). Obtained from https://celestrak.org/software/vallado-sw.php.
//
//  This is a *port*, not a reimplementation. Variable names, the order of
//  operations, the magic constants, the loop structures and the several
//  documented "sgp4fix" behaviours are all preserved deliberately, even where
//  Swift would let us write something tidier. TLEs are defined against this
//  exact model: any simplification (a two-body Keplerian propagation, dropped
//  periodic terms, a "cleaned up" Kepler solver) produces positions that are
//  simply wrong, by tens to hundreds of kilometres. The unit tests check the
//  port against the standard SGP4-VER verification vectors to sub-metre
//  agreement; that is the only evidence that this file is correct.
//
//  Both branches of the model are implemented:
//
//   * near-Earth (SGP4) for orbital periods under 225 minutes, and
//   * deep-space (SDP4) for periods of 225 minutes or more, which adds
//     lunar-solar secular and periodic terms and, for the 12- and 24-hour
//     resonance cases, a numerically integrated resonance model.
//
//  Deep space is not optional here: every MEO and GEO satellite in the
//  catalogue takes that branch.
//
//  Output is position and velocity in the **TEME** frame (True Equator, Mean
//  Equinox of date), in km and km/s. Converting that to something an observer
//  can point at is `TopocentricTransform`'s job, not this file's.
//

import Foundation

/// Gravity model selection. TLEs are generated against WGS-72, so `wgs72` is
/// the correct choice for propagating catalogue elements — using WGS-84
/// constants with WGS-72-derived elements introduces error rather than
/// removing it, which is why the reference test set is run with WGS-72.
enum SGP4GravityModel {
    case wgs72old
    case wgs72
    case wgs84

    /// (tumin, mu, radiusEarthKm, xke, j2, j3, j4, j3oj2)
    var constants: (tumin: Double, mu: Double, radiusEarthKm: Double, xke: Double,
                    j2: Double, j3: Double, j4: Double, j3oj2: Double) {
        switch self {
        case .wgs72old:
            let mu = 398_600.79964
            let radius = 6378.135
            let xke = 0.0743669161
            let j2 = 0.001082616, j3 = -0.00000253881, j4 = -0.00000165597
            return (1.0 / xke, mu, radius, xke, j2, j3, j4, j3 / j2)
        case .wgs72:
            let mu = 398_600.8
            let radius = 6378.135
            let xke = 60.0 / (radius * radius * radius / mu).squareRoot()
            let j2 = 0.001082616, j3 = -0.00000253881, j4 = -0.00000165597
            return (1.0 / xke, mu, radius, xke, j2, j3, j4, j3 / j2)
        case .wgs84:
            let mu = 398_600.5
            let radius = 6378.137
            let xke = 60.0 / (radius * radius * radius / mu).squareRoot()
            let j2 = 0.00108262998905, j3 = -0.00000253215306, j4 = -0.00000161098761
            return (1.0 / xke, mu, radius, xke, j2, j3, j4, j3 / j2)
        }
    }
}

/// AFSPC-compatible ('a') versus improved ('i') operation. The verification
/// vectors in the Vallado paper are produced in improved mode.
enum SGP4OperationMode {
    case afspc
    case improved
}

/// Non-fatal-but-unusable conditions the propagator can hit, numbered as in the
/// reference implementation so cross-checking against it stays easy.
enum SGP4Error: Int, Error {
    /// Mean eccentricity out of range (0 <= e < 1).
    case eccentricityOutOfRange = 1
    /// Mean motion went non-positive.
    case meanMotionNonPositive = 2
    /// Perturbed eccentricity out of range.
    case perturbedEccentricityOutOfRange = 3
    /// Semi-latus rectum went negative.
    case semiLatusRectumNegative = 4
    /// Satellite has decayed — the propagated radius is below the Earth's
    /// surface. Common for stale elements of objects that have since re-entered.
    case decayed = 6
}

/// One propagated state, in the TEME frame.
struct SGP4State: Hashable, Sendable {
    /// Position in kilometres.
    var position: SIMD3<Double>
    /// Velocity in kilometres per second.
    var velocity: SIMD3<Double>
}

/// The propagator. Holds the initialised element record (the reference's
/// `elsetrec`) and propagates it to any time offset from epoch.
///
/// `propagate` is `mutating` because the model genuinely carries state: the
/// deep-space resonance integrator remembers where it got to (`atime`, `xli`,
/// `xni`) so that stepping forward in time is incremental rather than
/// re-integrating from epoch every call, and the deep-space branch recomputes
/// `aycof`/`xlcof`/`con41` from the perturbed inclination. Each satellite
/// therefore needs its own propagator instance; they must not be shared across
/// concurrent propagations.
struct SGP4Propagator: Sendable {

    private static let twoPi = 2.0 * Double.pi
    private static let x2o3 = 2.0 / 3.0
    private static let deg2rad = Double.pi / 180.0

    // MARK: Element record

    private(set) var satelliteNumber: Int
    private var operationMode: SGP4OperationMode
    /// 'n' near-earth, 'd' deep space.
    private(set) var isDeepSpace: Bool = false
    private var isImp = false

    // Gravity constants, copied in so the hot loop never indirects.
    private let tumin, mu, radiusEarthKm, xke, j2, j3, j4, j3oj2: Double

    // Near-Earth secular/periodic coefficients.
    private var aycof = 0.0, con41 = 0.0, cc1 = 0.0, cc4 = 0.0, cc5 = 0.0
    private var d2 = 0.0, d3 = 0.0, d4 = 0.0, delmo = 0.0, eta = 0.0
    private var argpdot = 0.0, omgcof = 0.0, sinmao = 0.0
    private var t2cof = 0.0, t3cof = 0.0, t4cof = 0.0, t5cof = 0.0
    private var x1mth2 = 0.0, x7thm1 = 0.0, mdot = 0.0, nodedot = 0.0
    private var xlcof = 0.0, xmcof = 0.0, nodecf = 0.0

    // Deep-space terms.
    private var irez = 0
    private var d2201 = 0.0, d2211 = 0.0, d3210 = 0.0, d3222 = 0.0
    private var d4410 = 0.0, d4422 = 0.0, d5220 = 0.0, d5232 = 0.0
    private var d5421 = 0.0, d5433 = 0.0
    private var dedt = 0.0, del1 = 0.0, del2 = 0.0, del3 = 0.0
    private var didt = 0.0, dmdt = 0.0, dnodt = 0.0, domdt = 0.0
    private var e3 = 0.0, ee2 = 0.0, peo = 0.0, pgho = 0.0, pho = 0.0
    private var pinco = 0.0, plo = 0.0
    private var se2 = 0.0, se3 = 0.0, sgh2 = 0.0, sgh3 = 0.0, sgh4 = 0.0
    private var sh2 = 0.0, sh3 = 0.0, si2 = 0.0, si3 = 0.0
    private var sl2 = 0.0, sl3 = 0.0, sl4 = 0.0
    private var gsto = 0.0, xfact = 0.0
    private var xgh2 = 0.0, xgh3 = 0.0, xgh4 = 0.0, xh2 = 0.0, xh3 = 0.0
    private var xi2 = 0.0, xi3 = 0.0, xl2 = 0.0, xl3 = 0.0, xl4 = 0.0
    private var xlamo = 0.0, zmol = 0.0, zmos = 0.0
    private var atime = 0.0, xli = 0.0, xni = 0.0

    // Base elements.
    private(set) var semiMajorAxisEarthRadii = 0.0
    private var bstar = 0.0, inclo = 0.0, nodeo = 0.0, ecco = 0.0
    private var argpo = 0.0, mo = 0.0, noKozai = 0.0, noUnkozai = 0.0

    /// Days since 1949 Dec 31 00:00 UT.
    private(set) var epochDays: Double
    /// Julian Day of the element-set epoch.
    let epochJulianDay: Double

    /// Orbital period in minutes derived from the *unkozai'd* mean motion —
    /// the same quantity the model uses to choose its branch.
    var periodMinutes: Double { Self.twoPi / noUnkozai }

    // MARK: - Initialisation

    /// Initialises the propagator from a parsed element set. Returns nil if the
    /// elements are degenerate enough that initialisation cannot proceed.
    init?(tle: TwoLineElement,
          gravityModel: SGP4GravityModel = .wgs72,
          operationMode: SGP4OperationMode = .improved) {
        // Unit conversion, exactly as `twoline2rv` does it.
        let xpdotp = 1440.0 / (2.0 * Double.pi) // rev/day -> rad/min
        let noKozai = tle.meanMotionRevsPerDay / xpdotp
        guard noKozai > 0, tle.eccentricity >= 0, tle.eccentricity < 1 else { return nil }

        let constants = gravityModel.constants
        self.tumin = constants.tumin
        self.mu = constants.mu
        self.radiusEarthKm = constants.radiusEarthKm
        self.xke = constants.xke
        self.j2 = constants.j2
        self.j3 = constants.j3
        self.j4 = constants.j4
        self.j3oj2 = constants.j3oj2

        self.satelliteNumber = tle.catalogNumber
        self.operationMode = operationMode
        self.epochJulianDay = tle.epochJulianDay
        self.epochDays = tle.sgp4Epoch

        self.bstar = tle.bstar
        self.ecco = tle.eccentricity
        self.argpo = tle.argumentOfPerigeeDegrees * Self.deg2rad
        self.inclo = tle.inclinationDegrees * Self.deg2rad
        self.mo = tle.meanAnomalyDegrees * Self.deg2rad
        self.nodeo = tle.rightAscensionOfAscendingNodeDegrees * Self.deg2rad
        self.noKozai = noKozai

        initialise(epoch: tle.sgp4Epoch)
    }

    /// Port of `sgp4init`. The trailing `sgp4(satrec, 0.0, ...)` call in the
    /// reference exists only to populate the record's cached state; it is
    /// reproduced here for the same reason (the deep-space branch's
    /// `aycof`/`xlcof` are meant to reflect a completed propagation), and its
    /// result is intentionally discarded.
    private mutating func initialise(epoch: Double) {
        let temp4 = 1.5e-12
        let ss = 78.0 / radiusEarthKm + 1.0
        let qzms2ttemp = (120.0 - 78.0) / radiusEarthKm
        let qzms2t = qzms2ttemp * qzms2ttemp * qzms2ttemp * qzms2ttemp

        let initl = initl(epoch: epoch)
        let ao = initl.ao
        let cosio = initl.cosio, cosio2 = initl.cosio2
        let eccsq = initl.eccsq, omeosq = initl.omeosq, posq = initl.posq
        let rp = initl.rp, rteosq = initl.rteosq, sinio = initl.sinio
        let con42 = initl.con42
        con41 = initl.con41
        gsto = initl.gsto
        noUnkozai = initl.noUnkozai

        semiMajorAxisEarthRadii = pow(noUnkozai * tumin, -2.0 / 3.0)

        var sfour = ss
        var qzms24 = qzms2t
        var tsi = 0.0

        guard omeosq >= 0.0 || noUnkozai >= 0.0 else { return }

        isImp = false
        if rp < (220.0 / radiusEarthKm + 1.0) { isImp = true }

        let perige = (rp - 1.0) * radiusEarthKm
        if perige < 156.0 {
            sfour = perige - 78.0
            if perige < 98.0 { sfour = 20.0 }
            let qzms24temp = (120.0 - sfour) / radiusEarthKm
            qzms24 = qzms24temp * qzms24temp * qzms24temp * qzms24temp
            sfour = sfour / radiusEarthKm + 1.0
        }
        let pinvsq = 1.0 / posq
        tsi = 1.0 / (ao - sfour)
        eta = ao * ecco * tsi
        let etasq = eta * eta
        let eeta = ecco * eta
        let psisq = abs(1.0 - etasq)
        let coef = qzms24 * pow(tsi, 4.0)
        let coef1 = coef / pow(psisq, 3.5)
        let cc2 = coef1 * noUnkozai * (ao * (1.0 + 1.5 * etasq + eeta * (4.0 + etasq))
            + 0.375 * j2 * tsi / psisq * con41 * (8.0 + 3.0 * etasq * (8.0 + etasq)))
        cc1 = bstar * cc2

        var cc3 = 0.0
        if ecco > 1.0e-4 {
            cc3 = -2.0 * coef * tsi * j3oj2 * noUnkozai * sinio / ecco
        }
        x1mth2 = 1.0 - cosio2
        cc4 = 2.0 * noUnkozai * coef1 * ao * omeosq
            * (eta * (2.0 + 0.5 * etasq) + ecco * (0.5 + 2.0 * etasq)
               - j2 * tsi / (ao * psisq)
               * (-3.0 * con41 * (1.0 - 2.0 * eeta + etasq * (1.5 - 0.5 * eeta))
                  + 0.75 * x1mth2 * (2.0 * etasq - eeta * (1.0 + etasq)) * cos(2.0 * argpo)))
        cc5 = 2.0 * coef1 * ao * omeosq * (1.0 + 2.75 * (etasq + eeta) + eeta * etasq)

        let cosio4 = cosio2 * cosio2
        let temp1 = 1.5 * j2 * pinvsq * noUnkozai
        let temp2 = 0.5 * temp1 * j2 * pinvsq
        let temp3 = -0.46875 * j4 * pinvsq * pinvsq * noUnkozai
        mdot = noUnkozai + 0.5 * temp1 * rteosq * con41
            + 0.0625 * temp2 * rteosq * (13.0 - 78.0 * cosio2 + 137.0 * cosio4)
        argpdot = -0.5 * temp1 * con42
            + 0.0625 * temp2 * (7.0 - 114.0 * cosio2 + 395.0 * cosio4)
            + temp3 * (3.0 - 36.0 * cosio2 + 49.0 * cosio4)
        let xhdot1 = -temp1 * cosio
        nodedot = xhdot1 + (0.5 * temp2 * (4.0 - 19.0 * cosio2)
                            + 2.0 * temp3 * (3.0 - 7.0 * cosio2)) * cosio
        let xpidot = argpdot + nodedot
        omgcof = bstar * cc3 * cos(argpo)
        xmcof = 0.0
        if ecco > 1.0e-4 {
            xmcof = -Self.x2o3 * coef * bstar / eeta
        }
        nodecf = 3.5 * omeosq * xhdot1 * cc1
        t2cof = 1.5 * cc1
        if abs(cosio + 1.0) > 1.5e-12 {
            xlcof = -0.25 * j3oj2 * sinio * (3.0 + 5.0 * cosio) / (1.0 + cosio)
        } else {
            xlcof = -0.25 * j3oj2 * sinio * (3.0 + 5.0 * cosio) / temp4
        }
        aycof = -0.5 * j3oj2 * sinio
        let delmotemp = 1.0 + eta * cos(mo)
        delmo = delmotemp * delmotemp * delmotemp
        sinmao = sin(mo)
        x7thm1 = 7.0 * cosio2 - 1.0

        // Deep-space branch selection: period of 225 minutes or more.
        if (2.0 * Double.pi / noUnkozai) >= 225.0 {
            isDeepSpace = true
            isImp = true
            let tc = 0.0
            var inclm = inclo

            let common = dscom(epoch: epoch, ep: ecco, argpp: argpo, tc: tc,
                               inclp: inclo, nodep: nodeo, np: noUnkozai)

            // The initialisation call to `dpper` applies the *epoch* value of
            // the lunar-solar periodics to the base elements. `init == 'y'`
            // makes it use the epoch phase angles and skip the subtraction of
            // the stored zero-point terms.
            var ep = ecco, inclp = inclo, nodep = nodeo, argpp = argpo, mp = mo
            dpper(t: 0.0, isInit: true, inclo: inclm,
                  ep: &ep, inclp: &inclp, nodep: &nodep, argpp: &argpp, mp: &mp)
            ecco = ep; inclo = inclp; nodeo = nodep; argpo = argpp; mo = mp

            var argpm = 0.0, nodem = 0.0, mm = 0.0
            var em = common.em, nm = common.nm
            var dndt = 0.0
            inclm = inclo
            dsinit(common: common, tc: tc, xpidot: xpidot, eccsq: eccsq,
                   em: &em, argpm: &argpm, inclm: &inclm, mm: &mm, nm: &nm,
                   nodem: &nodem, dndt: &dndt)
        }

        if !isImp {
            let cc1sq = cc1 * cc1
            d2 = 4.0 * ao * tsi * cc1sq
            let temp = d2 * tsi * cc1 / 3.0
            d3 = (17.0 * ao + sfour) * temp
            d4 = 0.5 * temp * ao * tsi * (221.0 * ao + 31.0 * sfour) * cc1
            t3cof = d2 + 2.0 * cc1sq
            t4cof = 0.25 * (3.0 * d3 + cc1 * (12.0 * d2 + 10.0 * cc1sq))
            t5cof = 0.2 * (3.0 * d4 + 12.0 * cc1 * d3 + 6.0 * d2 * d2
                           + 15.0 * cc1sq * (2.0 * d2 + cc1sq))
        }

        _ = try? propagate(minutesSinceEpoch: 0.0)
    }

    /// Port of `initl`.
    private struct InitlResult {
        var ainv = 0.0, ao = 0.0, con41 = 0.0, con42 = 0.0, cosio = 0.0
        var cosio2 = 0.0, eccsq = 0.0, omeosq = 0.0, posq = 0.0
        var rp = 0.0, rteosq = 0.0, sinio = 0.0, gsto = 0.0, noUnkozai = 0.0
    }

    private func initl(epoch: Double) -> InitlResult {
        var out = InitlResult()
        out.eccsq = ecco * ecco
        out.omeosq = 1.0 - out.eccsq
        out.rteosq = out.omeosq.squareRoot()
        out.cosio = cos(inclo)
        out.cosio2 = out.cosio * out.cosio

        // Un-Kozai the mean motion: TLE mean motion is a Kozai mean element and
        // the model wants a Brouwer one.
        let ak = pow(xke / noKozai, Self.x2o3)
        let d1 = 0.75 * j2 * (3.0 * out.cosio2 - 1.0) / (out.rteosq * out.omeosq)
        var del = d1 / (ak * ak)
        let adel = ak * (1.0 - del * del - del * (1.0 / 3.0 + 134.0 * del * del / 81.0))
        del = d1 / (adel * adel)
        out.noUnkozai = noKozai / (1.0 + del)

        out.ao = pow(xke / out.noUnkozai, Self.x2o3)
        out.sinio = sin(inclo)
        let po = out.ao * out.omeosq
        out.con42 = 1.0 - 5.0 * out.cosio2
        out.con41 = -out.con42 - out.cosio2 - out.cosio2
        out.ainv = 1.0 / out.ao
        out.posq = po * po
        out.rp = out.ao * (1.0 - ecco)

        // sgp4fix: the reference computes an older `gsto1` here and then
        // discards it in favour of `gstime_SGP4`. Only the latter is kept.
        out.gsto = Self.gstime(julianDateUT1: epoch + 2_433_281.5)
        return out
    }

    /// Greenwich Mean Sidereal Time in radians, port of `gstime_SGP4`.
    ///
    /// The app's `CoordinateTransformService` has its own GMST for the star
    /// path; this one is kept separate and identical to the reference because
    /// the SGP4 deep-space resonance model is *defined* against it, and the
    /// verification vectors depend on it to the last digit.
    static func gstime(julianDateUT1 jdut1: Double) -> Double {
        let deg2rad = Double.pi / 180.0
        let tut1 = (jdut1 - 2_451_545.0) / 36_525.0
        var temp = -6.2e-6 * tut1 * tut1 * tut1
            + 0.093104 * tut1 * tut1
            + (876_600.0 * 3600.0 + 8_640_184.812866) * tut1
            + 67_310.54841
        temp = (temp * deg2rad / 240.0).truncatingRemainder(dividingBy: twoPi)
        if temp < 0.0 { temp += twoPi }
        return temp
    }

    // MARK: - Propagation

    /// Port of `sgp4`. Propagates to `minutesSinceEpoch` minutes from the
    /// element-set epoch and returns TEME position (km) and velocity (km/s).
    mutating func propagate(minutesSinceEpoch t: Double) throws -> SGP4State {
        let temp4 = 1.5e-12
        let vkmpersec = radiusEarthKm * xke / 60.0

        let xmdf = mo + mdot * t
        let argpdf = argpo + argpdot * t
        let nodedf = nodeo + nodedot * t
        var argpm = argpdf
        var mm = xmdf
        let t2 = t * t
        var nodem = nodedf + nodecf * t2
        var tempa = 1.0 - cc1 * t
        var tempe = bstar * cc4 * t
        var templ = t2cof * t2

        if !isImp {
            let delomg = omgcof * t
            let delmtemp = 1.0 + eta * cos(xmdf)
            let delm = xmcof * (delmtemp * delmtemp * delmtemp - delmo)
            let temp = delomg + delm
            mm = xmdf + temp
            argpm = argpdf - temp
            let t3 = t2 * t
            let t4 = t3 * t
            tempa = tempa - d2 * t2 - d3 * t3 - d4 * t4
            tempe = tempe + bstar * cc5 * (sin(mm) - sinmao)
            templ = templ + t3cof * t3 + t4 * (t4cof + t * t5cof)
        }

        var nm = noUnkozai
        var em = ecco
        var inclm = inclo

        if isDeepSpace {
            var dndt = 0.0
            dspace(t: t, tc: t, em: &em, argpm: &argpm, inclm: &inclm,
                   mm: &mm, nodem: &nodem, dndt: &dndt, nm: &nm)
        }

        guard nm > 0.0 else { throw SGP4Error.meanMotionNonPositive }

        let am = pow(xke / nm, Self.x2o3) * tempa * tempa
        nm = xke / pow(am, 1.5)
        em -= tempe
        guard em < 1.0, em >= -0.001 else { throw SGP4Error.eccentricityOutOfRange }
        if em < 1.0e-6 { em = 1.0e-6 }

        mm += noUnkozai * templ
        var xlm = mm + argpm + nodem
        nodem = nodem.truncatingRemainder(dividingBy: Self.twoPi)
        argpm = argpm.truncatingRemainder(dividingBy: Self.twoPi)
        xlm = xlm.truncatingRemainder(dividingBy: Self.twoPi)
        mm = (xlm - argpm - nodem).truncatingRemainder(dividingBy: Self.twoPi)

        let sinim = sin(inclm)
        let cosim = cos(inclm)

        var ep = em
        var xincp = inclm
        var argpp = argpm
        var nodep = nodem
        var mp = mm
        var sinip = sinim
        var cosip = cosim

        if isDeepSpace {
            dpper(t: t, isInit: false, inclo: inclo,
                  ep: &ep, inclp: &xincp, nodep: &nodep, argpp: &argpp, mp: &mp)
            if xincp < 0.0 {
                xincp = -xincp
                nodep += Double.pi
                argpp -= Double.pi
            }
            guard ep >= 0.0, ep <= 1.0 else { throw SGP4Error.perturbedEccentricityOutOfRange }

            sinip = sin(xincp)
            cosip = cos(xincp)
            aycof = -0.5 * j3oj2 * sinip
            if abs(cosip + 1.0) > 1.5e-12 {
                xlcof = -0.25 * j3oj2 * sinip * (3.0 + 5.0 * cosip) / (1.0 + cosip)
            } else {
                xlcof = -0.25 * j3oj2 * sinip * (3.0 + 5.0 * cosip) / temp4
            }
        }

        // Long-period periodics.
        let axnl = ep * cos(argpp)
        var temp = 1.0 / (am * (1.0 - ep * ep))
        let aynl = ep * sin(argpp) + temp * aycof
        let xl = mp + argpp + nodep + temp * xlcof * axnl

        // Kepler's equation, solved exactly as the reference does: at most ten
        // Newton iterations with the step clamped to +/-0.95 radians.
        let u = (xl - nodep).truncatingRemainder(dividingBy: Self.twoPi)
        var eo1 = u
        var tem5 = 9999.9
        var ktr = 1
        var sineo1 = 0.0, coseo1 = 0.0
        while abs(tem5) >= 1.0e-12 && ktr <= 10 {
            sineo1 = sin(eo1)
            coseo1 = cos(eo1)
            tem5 = 1.0 - coseo1 * axnl - sineo1 * aynl
            tem5 = (u - aynl * coseo1 + axnl * sineo1 - eo1) / tem5
            if abs(tem5) >= 0.95 { tem5 = tem5 > 0.0 ? 0.95 : -0.95 }
            eo1 += tem5
            ktr += 1
        }

        // Short-period periodics.
        let ecose = axnl * coseo1 + aynl * sineo1
        let esine = axnl * sineo1 - aynl * coseo1
        let el2 = axnl * axnl + aynl * aynl
        let pl = am * (1.0 - el2)
        guard pl >= 0.0 else { throw SGP4Error.semiLatusRectumNegative }

        let rl = am * (1.0 - ecose)
        let rdotl = am.squareRoot() * esine / rl
        let rvdotl = pl.squareRoot() / rl
        let betal = (1.0 - el2).squareRoot()
        temp = esine / (1.0 + betal)
        let sinu = am / rl * (sineo1 - aynl - axnl * temp)
        let cosu = am / rl * (coseo1 - axnl + aynl * temp)
        var su = atan2(sinu, cosu)
        let sin2u = (cosu + cosu) * sinu
        let cos2u = 1.0 - 2.0 * sinu * sinu
        temp = 1.0 / pl
        let temp1 = 0.5 * j2 * temp
        let temp2 = temp1 * temp

        // The deep-space branch re-derives these from the *perturbed*
        // inclination, so they must be recomputed here rather than reused from
        // initialisation.
        var con41Local = con41
        var x1mth2Local = x1mth2
        var x7thm1Local = x7thm1
        if isDeepSpace {
            let cosisq = cosip * cosip
            con41Local = 3.0 * cosisq - 1.0
            x1mth2Local = 1.0 - cosisq
            x7thm1Local = 7.0 * cosisq - 1.0
            con41 = con41Local
            x1mth2 = x1mth2Local
            x7thm1 = x7thm1Local
        }

        let mrt = rl * (1.0 - 1.5 * temp2 * betal * con41Local)
            + 0.5 * temp1 * x1mth2Local * cos2u
        su -= 0.25 * temp2 * x7thm1Local * sin2u
        let xnode = nodep + 1.5 * temp2 * cosip * sin2u
        let xinc = xincp + 1.5 * temp2 * cosip * sinip * cos2u
        let mvt = rdotl - nm * temp1 * x1mth2Local * sin2u / xke
        let rvdot = rvdotl + nm * temp1 * (x1mth2Local * cos2u + 1.5 * con41Local) / xke

        // Orientation vectors.
        let sinsu = sin(su), cossu = cos(su)
        let snod = sin(xnode), cnod = cos(xnode)
        let sini = sin(xinc), cosi = cos(xinc)
        let xmx = -snod * cosi
        let xmy = cnod * cosi
        let ux = xmx * sinsu + cnod * cossu
        let uy = xmy * sinsu + snod * cossu
        let uz = sini * sinsu
        let vx = xmx * cossu - cnod * sinsu
        let vy = xmy * cossu - snod * sinsu
        let vz = sini * cossu

        let position = SIMD3(mrt * ux, mrt * uy, mrt * uz) * radiusEarthKm
        let velocity = SIMD3(mvt * ux + rvdot * vx,
                             mvt * uy + rvdot * vy,
                             mvt * uz + rvdot * vz) * vkmpersec

        guard mrt >= 1.0 else { throw SGP4Error.decayed }
        return SGP4State(position: position, velocity: velocity)
    }

    /// Convenience: propagate to an absolute Julian Day.
    mutating func propagate(julianDay jd: Double) throws -> SGP4State {
        try propagate(minutesSinceEpoch: (jd - epochJulianDay) * 1440.0)
    }

    // MARK: - Deep space: dscom

    /// Everything `dscom` computes that later stages need but the record does
    /// not keep. Named exactly as in the reference so the two can be compared
    /// line by line.
    struct DeepSpaceCommon {
        var snodm = 0.0, cnodm = 0.0, sinim = 0.0, cosim = 0.0
        var sinomm = 0.0, cosomm = 0.0, day = 0.0
        var em = 0.0, emsq = 0.0, gam = 0.0, rtemsq = 0.0
        var s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0, s5 = 0.0, s6 = 0.0, s7 = 0.0
        var ss1 = 0.0, ss2 = 0.0, ss3 = 0.0, ss4 = 0.0, ss5 = 0.0, ss6 = 0.0, ss7 = 0.0
        var sz1 = 0.0, sz2 = 0.0, sz3 = 0.0
        var sz11 = 0.0, sz12 = 0.0, sz13 = 0.0
        var sz21 = 0.0, sz22 = 0.0, sz23 = 0.0
        var sz31 = 0.0, sz32 = 0.0, sz33 = 0.0
        var nm = 0.0
        var z1 = 0.0, z2 = 0.0, z3 = 0.0
        var z11 = 0.0, z12 = 0.0, z13 = 0.0
        var z21 = 0.0, z22 = 0.0, z23 = 0.0
        var z31 = 0.0, z32 = 0.0, z33 = 0.0
    }

    /// Port of `dscom`: the lunar-solar terms common to the deep-space
    /// initialisation. The two-pass loop runs the same algebra first with the
    /// Sun's orientation constants and then with the Moon's.
    private mutating func dscom(
        epoch: Double, ep: Double, argpp: Double, tc: Double,
        inclp: Double, nodep: Double, np: Double
    ) -> DeepSpaceCommon {
        let zes = 0.01675
        let zel = 0.05490
        let c1ss = 2.9864797e-6
        let c1l = 4.7968065e-7
        let zsinis = 0.39785416
        let zcosis = 0.91744867
        let zcosgs = 0.1945905
        let zsings = -0.98088458

        var out = DeepSpaceCommon()
        out.nm = np
        out.em = ep
        out.snodm = sin(nodep)
        out.cnodm = cos(nodep)
        out.sinomm = sin(argpp)
        out.cosomm = cos(argpp)
        out.sinim = sin(inclp)
        out.cosim = cos(inclp)
        out.emsq = out.em * out.em
        let betasq = 1.0 - out.emsq
        out.rtemsq = betasq.squareRoot()

        peo = 0.0; pinco = 0.0; plo = 0.0; pgho = 0.0; pho = 0.0

        out.day = epoch + 18_261.5 + tc / 1440.0
        let xnodce = (4.5236020 - 9.2422029e-4 * out.day)
            .truncatingRemainder(dividingBy: Self.twoPi)
        let stem = sin(xnodce)
        let ctem = cos(xnodce)
        let zcosil = 0.91375164 - 0.03568096 * ctem
        let zsinil = (1.0 - zcosil * zcosil).squareRoot()
        let zsinhl = 0.089683511 * stem / zsinil
        let zcoshl = (1.0 - zsinhl * zsinhl).squareRoot()
        out.gam = 5.8351514 + 0.0019443680 * out.day
        var zx = 0.39785416 * stem / zsinil
        let zy = zcoshl * ctem + 0.91744867 * zsinhl * stem
        zx = atan2(zx, zy)
        zx = out.gam + zx - xnodce
        let zcosgl = cos(zx)
        let zsingl = sin(zx)

        var zcosg = zcosgs
        var zsing = zsings
        var zcosi = zcosis
        var zsini = zsinis
        var zcosh = out.cnodm
        var zsinh = out.snodm
        var cc = c1ss
        let xnoi = 1.0 / out.nm

        for lsflg in 1...2 {
            let a1 = zcosg * zcosh + zsing * zcosi * zsinh
            let a3 = -zsing * zcosh + zcosg * zcosi * zsinh
            let a7 = -zcosg * zsinh + zsing * zcosi * zcosh
            let a8 = zsing * zsini
            let a9 = zsing * zsinh + zcosg * zcosi * zcosh
            let a10 = zcosg * zsini
            let a2 = out.cosim * a7 + out.sinim * a8
            let a4 = out.cosim * a9 + out.sinim * a10
            let a5 = -out.sinim * a7 + out.cosim * a8
            let a6 = -out.sinim * a9 + out.cosim * a10

            let x1 = a1 * out.cosomm + a2 * out.sinomm
            let x2 = a3 * out.cosomm + a4 * out.sinomm
            let x3 = -a1 * out.sinomm + a2 * out.cosomm
            let x4 = -a3 * out.sinomm + a4 * out.cosomm
            let x5 = a5 * out.sinomm
            let x6 = a6 * out.sinomm
            let x7 = a5 * out.cosomm
            let x8 = a6 * out.cosomm

            out.z31 = 12.0 * x1 * x1 - 3.0 * x3 * x3
            out.z32 = 24.0 * x1 * x2 - 6.0 * x3 * x4
            out.z33 = 12.0 * x2 * x2 - 3.0 * x4 * x4
            out.z1 = 3.0 * (a1 * a1 + a2 * a2) + out.z31 * out.emsq
            out.z2 = 6.0 * (a1 * a3 + a2 * a4) + out.z32 * out.emsq
            out.z3 = 3.0 * (a3 * a3 + a4 * a4) + out.z33 * out.emsq
            out.z11 = -6.0 * a1 * a5 + out.emsq * (-24.0 * x1 * x7 - 6.0 * x3 * x5)
            out.z12 = -6.0 * (a1 * a6 + a3 * a5) + out.emsq
                * (-24.0 * (x2 * x7 + x1 * x8) - 6.0 * (x3 * x6 + x4 * x5))
            out.z13 = -6.0 * a3 * a6 + out.emsq * (-24.0 * x2 * x8 - 6.0 * x4 * x6)
            out.z21 = 6.0 * a2 * a5 + out.emsq * (24.0 * x1 * x5 - 6.0 * x3 * x7)
            out.z22 = 6.0 * (a4 * a5 + a2 * a6) + out.emsq
                * (24.0 * (x2 * x5 + x1 * x6) - 6.0 * (x4 * x7 + x3 * x8))
            out.z23 = 6.0 * a4 * a6 + out.emsq * (24.0 * x2 * x6 - 6.0 * x4 * x8)
            out.z1 = out.z1 + out.z1 + betasq * out.z31
            out.z2 = out.z2 + out.z2 + betasq * out.z32
            out.z3 = out.z3 + out.z3 + betasq * out.z33
            out.s3 = cc * xnoi
            out.s2 = -0.5 * out.s3 / out.rtemsq
            out.s4 = out.s3 * out.rtemsq
            out.s1 = -15.0 * out.em * out.s4
            out.s5 = x1 * x3 + x2 * x4
            out.s6 = x2 * x3 + x1 * x4
            out.s7 = x2 * x4 - x1 * x3

            if lsflg == 1 {
                out.ss1 = out.s1; out.ss2 = out.s2; out.ss3 = out.s3
                out.ss4 = out.s4; out.ss5 = out.s5; out.ss6 = out.s6; out.ss7 = out.s7
                out.sz1 = out.z1; out.sz2 = out.z2; out.sz3 = out.z3
                out.sz11 = out.z11; out.sz12 = out.z12; out.sz13 = out.z13
                out.sz21 = out.z21; out.sz22 = out.z22; out.sz23 = out.z23
                out.sz31 = out.z31; out.sz32 = out.z32; out.sz33 = out.z33
                zcosg = zcosgl
                zsing = zsingl
                zcosi = zcosil
                zsini = zsinil
                zcosh = zcoshl * out.cnodm + zsinhl * out.snodm
                zsinh = out.snodm * zcoshl - out.cnodm * zsinhl
                cc = c1l
            }
        }

        zmol = (4.7199672 + 0.22997150 * out.day - out.gam)
            .truncatingRemainder(dividingBy: Self.twoPi)
        zmos = (6.2565837 + 0.017201977 * out.day)
            .truncatingRemainder(dividingBy: Self.twoPi)

        // Solar terms.
        se2 = 2.0 * out.ss1 * out.ss6
        se3 = 2.0 * out.ss1 * out.ss7
        si2 = 2.0 * out.ss2 * out.sz12
        si3 = 2.0 * out.ss2 * (out.sz13 - out.sz11)
        sl2 = -2.0 * out.ss3 * out.sz2
        sl3 = -2.0 * out.ss3 * (out.sz3 - out.sz1)
        sl4 = -2.0 * out.ss3 * (-21.0 - 9.0 * out.emsq) * zes
        sgh2 = 2.0 * out.ss4 * out.sz32
        sgh3 = 2.0 * out.ss4 * (out.sz33 - out.sz31)
        sgh4 = -18.0 * out.ss4 * zes
        sh2 = -2.0 * out.ss2 * out.sz22
        sh3 = -2.0 * out.ss2 * (out.sz23 - out.sz21)

        // Lunar terms.
        ee2 = 2.0 * out.s1 * out.s6
        e3 = 2.0 * out.s1 * out.s7
        xi2 = 2.0 * out.s2 * out.z12
        xi3 = 2.0 * out.s2 * (out.z13 - out.z11)
        xl2 = -2.0 * out.s3 * out.z2
        xl3 = -2.0 * out.s3 * (out.z3 - out.z1)
        xl4 = -2.0 * out.s3 * (-21.0 - 9.0 * out.emsq) * zel
        xgh2 = 2.0 * out.s4 * out.z32
        xgh3 = 2.0 * out.s4 * (out.z33 - out.z31)
        xgh4 = -18.0 * out.s4 * zel
        xh2 = -2.0 * out.s2 * out.z22
        xh3 = -2.0 * out.s2 * (out.z23 - out.z21)

        return out
    }

    // MARK: - Deep space: dpper

    /// Port of `dpper`: the lunar-solar *periodic* contributions, applied to
    /// the osculating elements at each propagation step (and once, with
    /// `isInit`, at initialisation).
    private func dpper(
        t: Double, isInit: Bool, inclo: Double,
        ep: inout Double, inclp: inout Double, nodep: inout Double,
        argpp: inout Double, mp: inout Double
    ) {
        let zns = 1.19459e-5
        let zes = 0.01675
        let znl = 1.5835218e-4
        let zel = 0.05490

        var zm = zmos + zns * t
        if isInit { zm = zmos }
        var zf = zm + 2.0 * zes * sin(zm)
        var sinzf = sin(zf)
        var f2 = 0.5 * sinzf * sinzf - 0.25
        var f3 = -0.5 * sinzf * cos(zf)
        let ses = se2 * f2 + se3 * f3
        let sis = si2 * f2 + si3 * f3
        let sls = sl2 * f2 + sl3 * f3 + sl4 * sinzf
        let sghs = sgh2 * f2 + sgh3 * f3 + sgh4 * sinzf
        var shs = sh2 * f2 + sh3 * f3

        zm = zmol + znl * t
        if isInit { zm = zmol }
        zf = zm + 2.0 * zel * sin(zm)
        sinzf = sin(zf)
        f2 = 0.5 * sinzf * sinzf - 0.25
        f3 = -0.5 * sinzf * cos(zf)
        let sel = ee2 * f2 + e3 * f3
        let sil = xi2 * f2 + xi3 * f3
        let sll = xl2 * f2 + xl3 * f3 + xl4 * sinzf
        let sghl = xgh2 * f2 + xgh3 * f3 + xgh4 * sinzf
        let shll = xh2 * f2 + xh3 * f3

        var pe = ses + sel
        var pinc = sis + sil
        var pl = sls + sll
        var pgh = sghs + sghl
        var ph = shs + shll

        guard !isInit else { return }

        pe -= peo
        pinc -= pinco
        pl -= plo
        pgh -= pgho
        ph -= pho

        inclp += pinc
        ep += pe
        let sinip = sin(inclp)
        let cosip = cos(inclp)

        // The Lyddane modification: near-equatorial orbits are handled in an
        // alternative set of variables, because the standard formulation
        // divides by sin(i).
        if inclp >= 0.2 {
            ph = ph / sinip
            pgh = pgh - cosip * ph
            argpp += pgh
            nodep += ph
            mp += pl
        } else {
            let sinop = sin(nodep)
            let cosop = cos(nodep)
            var alfdp = sinip * sinop
            var betdp = sinip * cosop
            let dalf = ph * cosop + pinc * cosip * sinop
            let dbet = -ph * sinop + pinc * cosip * cosop
            alfdp += dalf
            betdp += dbet
            nodep = nodep.truncatingRemainder(dividingBy: Self.twoPi)
            if nodep < 0.0 && operationMode == .afspc { nodep += Self.twoPi }
            var xls = mp + argpp + cosip * nodep
            let dls = pl + pgh - pinc * nodep * sinip
            xls += dls
            let xnoh = nodep
            nodep = atan2(alfdp, betdp)
            if nodep < 0.0 && operationMode == .afspc { nodep += Self.twoPi }
            if abs(xnoh - nodep) > Double.pi {
                if nodep < xnoh {
                    nodep += Self.twoPi
                } else {
                    nodep -= Self.twoPi
                }
            }
            mp += pl
            argpp = xls - mp - cosip * nodep
        }
    }

    // MARK: - Deep space: dsinit

    /// Port of `dsinit`: sets up the lunar-solar secular rates and, when the
    /// orbit is resonant, the 12-hour (`irez == 2`) or 24-hour (`irez == 1`)
    /// resonance coefficients that `dspace` integrates.
    private mutating func dsinit(
        common: DeepSpaceCommon, tc: Double, xpidot: Double, eccsq: Double,
        em: inout Double, argpm: inout Double, inclm: inout Double,
        mm: inout Double, nm: inout Double, nodem: inout Double, dndt: inout Double
    ) {
        let q22 = 1.7891679e-6
        let q31 = 2.1460748e-6
        let q33 = 2.2123015e-7
        let root22 = 1.7891679e-6
        let root44 = 7.3636953e-9
        let root54 = 2.1765803e-9
        let rptim = 4.37526908801129966e-3 // Earth rotation rate, rad/min
        let root32 = 3.7393792e-7
        let root52 = 1.1428639e-7
        let znl = 1.5835218e-4
        let zns = 1.19459e-5

        let cosim = common.cosim, sinim = common.sinim
        var emsq = common.emsq
        let s1 = common.s1, s2 = common.s2, s3 = common.s3, s4 = common.s4, s5 = common.s5
        let ss1 = common.ss1, ss2 = common.ss2, ss3 = common.ss3, ss4 = common.ss4, ss5 = common.ss5
        let sz1 = common.sz1, sz3 = common.sz3
        let sz11 = common.sz11, sz13 = common.sz13
        let sz21 = common.sz21, sz23 = common.sz23
        let sz31 = common.sz31, sz33 = common.sz33
        let z1 = common.z1, z3 = common.z3
        let z11 = common.z11, z13 = common.z13
        let z21 = common.z21, z23 = common.z23
        let z31 = common.z31, z33 = common.z33

        irez = 0
        if nm < 0.0052359877 && nm > 0.0034906585 { irez = 1 }
        if nm >= 8.26e-3 && nm <= 9.24e-3 && em >= 0.5 { irez = 2 }

        // Solar secular terms.
        let ses = ss1 * zns * ss5
        let sis = ss2 * zns * (sz11 + sz13)
        let sls = -zns * ss3 * (sz1 + sz3 - 14.0 - 6.0 * emsq)
        let sghs = ss4 * zns * (sz31 + sz33 - 6.0)
        var shs = -zns * ss2 * (sz21 + sz23)
        if inclm < 5.2359877e-2 || inclm > Double.pi - 5.2359877e-2 { shs = 0.0 }
        if sinim != 0.0 { shs = shs / sinim }
        let sgs = sghs - cosim * shs

        // Lunar secular terms.
        dedt = ses + s1 * znl * s5
        didt = sis + s2 * znl * (z11 + z13)
        dmdt = sls - znl * s3 * (z1 + z3 - 14.0 - 6.0 * emsq)
        let sghl = s4 * znl * (z31 + z33 - 6.0)
        var shll = -znl * s2 * (z21 + z23)
        if inclm < 5.2359877e-2 || inclm > Double.pi - 5.2359877e-2 { shll = 0.0 }
        domdt = sgs + sghl
        dnodt = shs
        if sinim != 0.0 {
            domdt = domdt - cosim / sinim * shll
            dnodt = dnodt + shll / sinim
        }

        dndt = 0.0
        let theta = (gsto + tc * rptim).truncatingRemainder(dividingBy: Self.twoPi)
        // `t` is zero at initialisation, so these are no-ops there; they are
        // kept because the reference keeps them.
        em += dedt * 0.0
        inclm += didt * 0.0
        argpm += domdt * 0.0
        nodem += dnodt * 0.0
        mm += dmdt * 0.0

        guard irez != 0 else { return }

        let aonv = pow(nm / xke, Self.x2o3)

        if irez == 2 {
            // 12-hour resonance (Molniya-type).
            let cosisq = cosim * cosim
            let emo = em
            em = ecco
            let emsqo = emsq
            emsq = eccsq
            let eoc = em * emsq

            let g201 = -0.306 - (em - 0.64) * 0.440
            var g211 = 0.0, g310 = 0.0, g322 = 0.0, g410 = 0.0, g422 = 0.0, g520 = 0.0
            if em <= 0.65 {
                g211 = 3.616 - 13.2470 * em + 16.2900 * emsq
                g310 = -19.302 + 117.3900 * em - 228.4190 * emsq + 156.5910 * eoc
                g322 = -18.9068 + 109.7927 * em - 214.6334 * emsq + 146.5816 * eoc
                g410 = -41.122 + 242.6940 * em - 471.0940 * emsq + 313.9530 * eoc
                g422 = -146.407 + 841.8800 * em - 1629.014 * emsq + 1083.4350 * eoc
                g520 = -532.114 + 3017.977 * em - 5740.032 * emsq + 3708.2760 * eoc
            } else {
                g211 = -72.099 + 331.819 * em - 508.738 * emsq + 266.724 * eoc
                g310 = -346.844 + 1582.851 * em - 2415.925 * emsq + 1246.113 * eoc
                g322 = -342.585 + 1554.908 * em - 2366.899 * emsq + 1215.972 * eoc
                g410 = -1052.797 + 4758.686 * em - 7193.992 * emsq + 3651.957 * eoc
                g422 = -3581.690 + 16178.110 * em - 24462.770 * emsq + 12422.520 * eoc
                if em > 0.715 {
                    g520 = -5149.66 + 29936.92 * em - 54087.36 * emsq + 31324.56 * eoc
                } else {
                    g520 = 1464.74 - 4664.75 * em + 3763.64 * emsq
                }
            }
            var g533 = 0.0, g521 = 0.0, g532 = 0.0
            if em < 0.7 {
                g533 = -919.22770 + 4988.6100 * em - 9064.7700 * emsq + 5542.21 * eoc
                g521 = -822.71072 + 4568.6173 * em - 8491.4146 * emsq + 5337.524 * eoc
                g532 = -853.66600 + 4690.2500 * em - 8624.7700 * emsq + 5341.4 * eoc
            } else {
                g533 = -37995.780 + 161616.52 * em - 229838.20 * emsq + 109377.94 * eoc
                g521 = -51752.104 + 218913.95 * em - 309468.16 * emsq + 146349.42 * eoc
                g532 = -40023.880 + 170470.89 * em - 242699.48 * emsq + 115605.82 * eoc
            }

            let sini2 = sinim * sinim
            let f220 = 0.75 * (1.0 + 2.0 * cosim + cosisq)
            let f221 = 1.5 * sini2
            let f321 = 1.875 * sinim * (1.0 - 2.0 * cosim - 3.0 * cosisq)
            let f322 = -1.875 * sinim * (1.0 + 2.0 * cosim - 3.0 * cosisq)
            let f441 = 35.0 * sini2 * f220
            let f442 = 39.3750 * sini2 * sini2
            let f522 = 9.84375 * sinim * (sini2 * (1.0 - 2.0 * cosim - 5.0 * cosisq)
                + 0.33333333 * (-2.0 + 4.0 * cosim + 6.0 * cosisq))
            let f523 = sinim * (4.92187512 * sini2 * (-2.0 - 4.0 * cosim + 10.0 * cosisq)
                + 6.56250012 * (1.0 + 2.0 * cosim - 3.0 * cosisq))
            let f542 = 29.53125 * sinim * (2.0 - 8.0 * cosim + cosisq
                * (-12.0 + 8.0 * cosim + 10.0 * cosisq))
            let f543 = 29.53125 * sinim * (-2.0 - 8.0 * cosim + cosisq
                * (12.0 + 8.0 * cosim - 10.0 * cosisq))

            let xno2 = nm * nm
            let ainv2 = aonv * aonv
            var temp1 = 3.0 * xno2 * ainv2
            var temp = temp1 * root22
            d2201 = temp * f220 * g201
            d2211 = temp * f221 * g211
            temp1 = temp1 * aonv
            temp = temp1 * root32
            d3210 = temp * f321 * g310
            d3222 = temp * f322 * g322
            temp1 = temp1 * aonv
            temp = 2.0 * temp1 * root44
            d4410 = temp * f441 * g410
            d4422 = temp * f442 * g422
            temp1 = temp1 * aonv
            temp = temp1 * root52
            d5220 = temp * f522 * g520
            d5232 = temp * f523 * g532
            temp = 2.0 * temp1 * root54
            d5421 = temp * f542 * g521
            d5433 = temp * f543 * g533

            xlamo = (mo + nodeo + nodeo - theta - theta)
                .truncatingRemainder(dividingBy: Self.twoPi)
            xfact = mdot + dmdt + 2.0 * (nodedot + dnodt - rptim) - noUnkozai
            em = emo
            emsq = emsqo
        }

        if irez == 1 {
            // 24-hour (geosynchronous) resonance.
            let g200 = 1.0 + emsq * (-2.5 + 0.8125 * emsq)
            let g310 = 1.0 + 2.0 * emsq
            let g300 = 1.0 + emsq * (-6.0 + 6.60937 * emsq)
            let f220 = 0.75 * (1.0 + cosim) * (1.0 + cosim)
            let f311 = 0.9375 * sinim * sinim * (1.0 + 3.0 * cosim) - 0.75 * (1.0 + cosim)
            var f330 = 1.0 + cosim
            f330 = 1.875 * f330 * f330 * f330
            del1 = 3.0 * nm * nm * aonv * aonv
            del2 = 2.0 * del1 * f220 * g200 * q22
            del3 = 3.0 * del1 * f330 * g300 * q33 * aonv
            del1 = del1 * f311 * g310 * q31 * aonv
            xlamo = (mo + nodeo + argpo - theta).truncatingRemainder(dividingBy: Self.twoPi)
            xfact = mdot + xpidot - rptim + dmdt + domdt + dnodt - noUnkozai
        }

        xli = xlamo
        xni = noUnkozai
        atime = 0.0
        nm = noUnkozai + dndt
    }

    // MARK: - Deep space: dspace

    /// Port of `dspace`: applies the lunar-solar secular rates and, for
    /// resonant orbits, integrates the resonance equations forward in fixed
    /// 720-minute steps from the last integrated time.
    ///
    /// The stepping is deliberately *not* replaced with a closed form. The
    /// integration is part of the model's definition, and the reference's
    /// state carry-over (`atime`, `xli`, `xni`) is what makes repeated forward
    /// propagation cheap: stepping from t to t+0.25s reuses the integration
    /// already done rather than restarting at epoch.
    private mutating func dspace(
        t: Double, tc: Double,
        em: inout Double, argpm: inout Double, inclm: inout Double,
        mm: inout Double, nodem: inout Double, dndt: inout Double, nm: inout Double
    ) {
        let fasx2 = 0.13130908
        let fasx4 = 2.8843198
        let fasx6 = 0.37448087
        let g22 = 5.7686396
        let g32 = 0.95240898
        let g44 = 1.8014998
        let g52 = 1.0508330
        let g54 = 4.4108898
        let rptim = 4.37526908801129966e-3
        let stepp = 720.0
        let stepn = -720.0
        let step2 = 259_200.0

        dndt = 0.0
        let theta = (gsto + tc * rptim).truncatingRemainder(dividingBy: Self.twoPi)
        em += dedt * t
        inclm += didt * t
        argpm += domdt * t
        nodem += dnodt * t
        mm += dmdt * t

        var ft = 0.0
        guard irez != 0 else { return }

        // Restart the integration if the target time is behind where we are, or
        // on the other side of epoch.
        if atime == 0.0 || t * atime <= 0.0 || abs(t) < abs(atime) {
            atime = 0.0
            xni = noUnkozai
            xli = xlamo
        }
        let delt = t > 0.0 ? stepp : stepn

        var xndt = 0.0, xldot = 0.0, xnddt = 0.0
        var iretn = 381
        while iretn == 381 {
            if irez != 2 {
                // Geopotential resonance for 24-hour satellites.
                xndt = del1 * sin(xli - fasx2)
                    + del2 * sin(2.0 * (xli - fasx4))
                    + del3 * sin(3.0 * (xli - fasx6))
                xldot = xni + xfact
                xnddt = del1 * cos(xli - fasx2)
                    + 2.0 * del2 * cos(2.0 * (xli - fasx4))
                    + 3.0 * del3 * cos(3.0 * (xli - fasx6))
                xnddt = xnddt * xldot
            } else {
                // 12-hour resonance terms.
                let xomi = argpo + argpdot * atime
                let x2omi = xomi + xomi
                let x2li = xli + xli
                xndt = d2201 * sin(x2omi + xli - g22) + d2211 * sin(xli - g22)
                    + d3210 * sin(xomi + xli - g32) + d3222 * sin(-xomi + xli - g32)
                    + d4410 * sin(x2omi + x2li - g44) + d4422 * sin(x2li - g44)
                    + d5220 * sin(xomi + xli - g52) + d5232 * sin(-xomi + xli - g52)
                    + d5421 * sin(xomi + x2li - g54) + d5433 * sin(-xomi + x2li - g54)
                xldot = xni + xfact
                xnddt = d2201 * cos(x2omi + xli - g22) + d2211 * cos(xli - g22)
                    + d3210 * cos(xomi + xli - g32) + d3222 * cos(-xomi + xli - g32)
                    + d5220 * cos(xomi + xli - g52) + d5232 * cos(-xomi + xli - g52)
                    + 2.0 * (d4410 * cos(x2omi + x2li - g44)
                             + d4422 * cos(x2li - g44)
                             + d5421 * cos(xomi + x2li - g54)
                             + d5433 * cos(-xomi + x2li - g54))
                xnddt = xnddt * xldot
            }

            if abs(t - atime) >= stepp {
                iretn = 381
            } else {
                ft = t - atime
                iretn = 0
            }

            if iretn == 381 {
                xli = xli + xldot * delt + xndt * step2
                xni = xni + xndt * delt + xnddt * step2
                atime = atime + delt
            }
        }

        nm = xni + xndt * ft + xnddt * ft * ft * 0.5
        let xl = xli + xldot * ft + xndt * ft * ft * 0.5
        if irez != 1 {
            mm = xl - 2.0 * nodem + 2.0 * theta
        } else {
            mm = xl - nodem - argpm + theta
        }
        dndt = nm - noUnkozai
        nm = noUnkozai + dndt
    }
}
