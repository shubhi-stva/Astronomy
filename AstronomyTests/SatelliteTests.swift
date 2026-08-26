//
//  SatelliteTests.swift
//  AstronomyTests
//
//  Tests for the satellite stack: the SGP4/SDP4 port, TLE parsing, the
//  topocentric transform, and the illumination model.
//
//  The SGP4 tests are the important ones, and they are not "does it run"
//  tests. SGP4 is a model with a single correct answer, published as a
//  verification set with the reference implementation. A port that agrees to
//  metres is right; one that is off by tens of kilometres is wrong in a way no
//  amount of eyeballing the screen would catch, because a wrong satellite
//  position still looks like a satellite. So the tolerances below are tight on
//  purpose and must not be relaxed to make a change pass.
//
//  Note: every test here is synchronous. The project has a known bug where an
//  `async` XCTest crashes the test host.
//

import XCTest
import simd
@testable import Astronomy

/// One entry from the standard verification set.
struct SGP4VerificationCase {
    let catalogNumber: Int
    let note: String
    let line1: String
    let line2: String
    /// (minutes from epoch, expected position km, expected velocity km/s)
    let expected: [(Double, SIMD3<Double>, SIMD3<Double>)]
}

final class SGP4VerificationTests: XCTestCase {

    /// Verification cases lifted from the standard `SGP4-VER.TLE` set that
    /// ships with Vallado's reference implementation. The expected state
    /// vectors were produced by compiling that reference C++ unmodified and
    /// recording its output, so these are the reference's own numbers rather
    /// than a transcription from a paper.
    ///
    /// Every branch of the model is represented: near-Earth with and without
    /// deep drag, both deep-space resonance cases, the Lyddane low-inclination
    /// path, backwards propagation, and a case propagated years past epoch.
    static let sgp4VerificationCases: [SGP4VerificationCase] = [
        SGP4VerificationCase(
            catalogNumber: 5,
            note: "near-Earth, the canonical first case of the verification set",
            line1: "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753",
            line2: "2 00005  34.2682 348.7242 1859667 331.7664  19.3264 10.82419157413667",
            expected: [
                (0.0, SIMD3(7022.46529266, -1400.08296755, 0.03995155), SIMD3(1.893841015, 6.405893759, 4.534807250)),
                (720.0, SIMD3(-7134.59340119, 6531.68641334, 3260.27186483), SIMD3(-4.113793027, -2.911922039, -2.557327851)),
                (2160.0, SIMD3(190.19796988, 7746.96653614, 5110.00675412), SIMD3(-6.112325142, 1.527008184, -0.139152358)),
                (4320.0, SIMD3(-9060.47373569, 4658.70952502, 813.68673153), SIMD3(-2.232832783, -4.110453490, -3.157345433)),
            ]
        ),
        SGP4VerificationCase(
            catalogNumber: 6251,
            note: "near-Earth with significant drag (the isimp deep-drag path)",
            line1: "1 06251U 62025E   06176.82412014  .00008885  00000-0  12808-3 0  3985",
            line2: "2 06251  58.0579  54.0425 0030035 139.1568 221.1854 15.56387291  6774",
            expected: [
                (0.0, SIMD3(3988.31022699, 5498.96657235, 0.90055879), SIMD3(-3.290032738, 2.357652820, 6.496623475)),
                (960.0, SIMD3(-4990.91637950, -2303.42547880, 3920.86335598), SIMD3(-0.993439372, -5.967458360, -4.759110856)),
                (1920.0, SIMD3(2954.49390331, -2080.65984650, -5754.75038057), SIMD3(4.895893306, 5.858184322, 0.375474825)),
                (2880.0, SIMD3(1159.27802897, 5056.60175495, 4353.49418579), SIMD3(-5.968060341, -2.314790406, 4.230722669)),
            ]
        ),
        SGP4VerificationCase(
            catalogNumber: 28057,
            note: "near-Earth, low perigee",
            line1: "1 28057U 03049A   06177.78615833  .00000060  00000-0  35940-4 0  1836",
            line2: "2 28057  98.4283 247.6961 0000884  88.1964 271.9322 14.35478080140550",
            expected: [
                (0.0, SIMD3(-2715.28237486, -6619.26436889, -0.01341443), SIMD3(-1.008587273, 0.422782003, 7.385272942)),
                (1440.0, SIMD3(688.16056594, 4124.87618964, 5794.55994449), SIMD3(2.810973665, 5.479585563, -4.224866316)),
                (2880.0, SIMD3(1788.42334580, 1990.50530957, -6640.59337725), SIMD3(-2.074169091, -6.683381288, -2.562777776)),
            ]
        ),
        SGP4VerificationCase(
            catalogNumber: 88888,
            note: "near-Earth, the original Spacetrack Report #3 test object",
            line1: "1 88888U          80275.98708465  .00073094  13844-3  66816-4 0    87",
            line2: "2 88888  72.8435 115.9689 0086731  52.6988 110.5714 16.05824518  1058",
            expected: [
                (0.0, SIMD3(2328.96975262, -5995.22051338, 1719.97297192), SIMD3(2.912073281, -0.983417956, -7.090816210)),
                (720.0, SIMD3(2567.56229695, -6112.50383922, 713.96374435), SIMD3(2.440245751, 0.098109002, -7.319959258)),
                (1440.0, SIMD3(2742.55398832, -6079.67009123, -326.39012649), SIMD3(1.948497651, 1.211072678, -7.356193131)),
            ]
        ),
        SGP4VerificationCase(
            catalogNumber: 4632,
            note: "deep space, propagated backwards from epoch",
            line1: "1 04632U 70093B   04031.91070959 -.00000084  00000-0  10000-3 0  9955",
            line2: "2 04632  11.4628 273.1101 1450506 207.6000 143.9350  1.20231981 44145",
            expected: [
                (-5184.0, SIMD3(-29020.02587128, 13819.84419063, -5713.33679183), SIMD3(-1.768068390, -3.235371192, -0.395206135)),
                (-5064.0, SIMD3(-32982.56870101, -11125.54996609, -6803.28472771), SIMD3(0.617446996, -3.379240041, 0.085954707)),
                (-4944.0, SIMD3(-22097.68730513, -31583.13829284, -4836.34329328), SIMD3(2.230597499, -2.166594667, 0.426443070)),
            ]
        ),
        SGP4VerificationCase(
            catalogNumber: 9880,
            note: "deep space, 12-hour resonance (irez == 2)",
            line1: "1 09880U 77021A   06176.56157475  .00000421  00000-0  10000-3 0  9814",
            line2: "2 09880  64.5968 349.3786 7069051 270.0229  16.3320  2.00813614112380",
            expected: [
                (0.0, SIMD3(13020.06750784, -2449.07193500, 1.15896030), SIMD3(4.247363935, 1.597178501, 4.956708611)),
                (1440.0, SIMD3(14369.90303735, -1903.85601062, 1722.15319852), SIMD3(3.543393116, 1.701687176, 4.913881358)),
                (2880.0, SIMD3(15500.53445068, -1332.90981042, 3419.72315308), SIMD3(2.960917974, 1.758331634, 4.813698638)),
            ]
        ),
        SGP4VerificationCase(
            catalogNumber: 23333,
            note: "deep space, high eccentricity",
            line1: "1 23333U 94071A   94305.49999999 -.00172956  26967-3  10000-3 0    15",
            line2: "2 23333  28.7490   2.3720 9728298  30.4360   1.3500  0.07309491    70",
            expected: [
                (0.0, SIMD3(-9301.24542292, 3326.10200382, 2318.36441127), SIMD3(-8.729303005, -0.828225037, -0.122314827)),
                (720.0, SIMD3(-127965.80064891, -43363.32967164, -19809.90480432), SIMD3(-1.789652016, -0.888278463, -0.441254468)),
                (1560.0, SIMD3(-197898.69401409, -80928.29015181, -38698.57972447), SIMD3(-1.204211888, -0.672544709, -0.340413731)),
            ]
        ),
        SGP4VerificationCase(
            catalogNumber: 23599,
            note: "deep space, near-critical inclination with the Lyddane path",
            line1: "1 23599U 95029B   06171.76535463  .00085586  12891-6  12956-2 0  2905",
            line2: "2 23599   6.9327   0.2849 5782022 274.4436  25.2425  4.47796565123555",
            expected: [
                (0.0, SIMD3(9892.63794341, 35.76144969, -1.08228838), SIMD3(3.556643237, 6.456009375, 0.783610890)),
                (360.0, SIMD3(11376.23941678, 12858.97121366, 1563.40660172), SIMD3(-1.087665695, 4.374693347, 0.532207051)),
                (720.0, SIMD3(7140.41945884, 20539.25485336, 2501.21469368), SIMD3(-2.293173684, 2.333507912, 0.282716311)),
            ]
        ),
        SGP4VerificationCase(
            catalogNumber: 20413,
            note: "deep space, very high altitude, propagated 3.5 years past epoch",
            line1: "1 20413U 83020D   05363.79166667  .00000000  00000-0  00000+0 0  7041",
            line2: "2 20413  12.3514 187.4253 7864447 196.3027 356.5478  0.24690082  7978",
            expected: [
                (1844000.0, SIMD3(-35697.35025451, -70749.92495964, 14190.12461545), SIMD3(1.649636113, 1.769993942, -0.576290053)),
                (1844170.0, SIMD3(-17163.94050833, -48981.47771614, 7620.37084880), SIMD3(2.013607877, 2.625684710, -0.728516169)),
                (1844340.0, SIMD3(5091.55546380, -5030.01134361, -1222.14210549), SIMD3(0.252792005, 10.276493768, -0.621814132)),
            ]
        ),
        SGP4VerificationCase(
            catalogNumber: 33335,
            note: "deep space, 24-hour geosynchronous resonance (irez == 1)",
            line1: "1 33335U 05008A   06176.46683397 -.00000205  00000-0  10000-3 0  2190",
            line2: "2 33335   0.0019 286.9433 0000004  13.7918  55.6504  1.00270176  4891",
            expected: [
                (0.0, SIMD3(42081.34386081, -2649.18487875, 0.81820315), SIMD3(0.193184518, 3.068627007, 0.000438443)),
                (720.0, SIMD3(-42102.56627900, 2288.73420969, -0.13297887), SIMD3(-0.166894449, -3.070164473, -0.000311012)),
                (1440.0, SIMD3(42120.60775638, -1928.11061608, -0.19841236), SIMD3(0.140602589, 3.071483058, 0.000179558)),
            ]
        ),
        SGP4VerificationCase(
            catalogNumber: 29238,
            note: "deep space, low inclination (the sub-0.2-radian Lyddane branch)",
            line1: "1 29238U 06022G   06177.28732010  .00766286  10823-4  13334-2 0   101",
            line2: "2 29238  51.5595 213.7903 0202579  95.2503 267.9010 15.73823839  1061",
            expected: [
                (0.0, SIMD3(-5566.59512819, -3789.75991159, 67.60382245), SIMD3(2.873759367, -3.825340523, 6.023253926)),
                (720.0, SIMD3(-5776.81371622, -118.64155319, -3641.22052418), SIMD3(-2.539917207, -5.622701582, 4.403125405)),
                (1440.0, SIMD3(-2629.55011449, 3400.98040158, -5344.38217129), SIMD3(-6.368548448, -3.998963509, 0.577253064)),
            ]
        ),
    ]

    /// The headline test: every case, every time step, position within one
    /// metre of the reference.
    ///
    /// One metre is roughly a thousand times tighter than the "~1 km" a correct
    /// port is expected to reach, and that is the point — a genuine port
    /// reproduces the reference to floating-point noise, so anything looser
    /// would be hiding a real error rather than allowing for one.
    func testMatchesReferenceStateVectors() throws {
        var worstPositionError = 0.0
        var worstVelocityError = 0.0
        var comparisons = 0

        for testCase in Self.sgp4VerificationCases {
            guard let tle = TwoLineElement.parse(
                name: nil, line1: testCase.line1, line2: testCase.line2
            ) else {
                XCTFail("failed to parse element set for \(testCase.catalogNumber)")
                continue
            }
            XCTAssertEqual(tle.catalogNumber, testCase.catalogNumber)

            guard var propagator = SGP4Propagator(tle: tle) else {
                XCTFail("failed to initialise propagator for \(testCase.catalogNumber)")
                continue
            }

            for (minutes, expectedPosition, expectedVelocity) in testCase.expected {
                let state = try propagator.propagate(minutesSinceEpoch: minutes)
                let positionError = simd_distance(state.position, expectedPosition)
                let velocityError = simd_distance(state.velocity, expectedVelocity)
                worstPositionError = max(worstPositionError, positionError)
                worstVelocityError = max(worstVelocityError, velocityError)
                comparisons += 1

                XCTAssertLessThan(
                    positionError, 0.001,
                    "\(testCase.catalogNumber) (\(testCase.note)) at t=\(minutes) min: "
                        + "position off by \(positionError) km"
                )
                XCTAssertLessThan(
                    velocityError, 1e-6,
                    "\(testCase.catalogNumber) at t=\(minutes) min: "
                        + "velocity off by \(velocityError) km/s"
                )
            }
        }

        XCTAssertGreaterThan(comparisons, 30, "the verification set should not have shrunk")
        print("SGP4 verification: \(comparisons) state vectors, "
              + "worst position residual \(worstPositionError) km, "
              + "worst velocity residual \(worstVelocityError) km/s")
    }

    /// Both model branches must actually be exercised. If a refactor
    /// accidentally routed every satellite through the near-Earth path this
    /// test fails even though the deep-space vectors above might still pass by
    /// coincidence on one or two cases.
    func testBothNearEarthAndDeepSpaceBranchesAreExercised() throws {
        var nearEarth = 0
        var deepSpace = 0
        for testCase in Self.sgp4VerificationCases {
            guard let tle = TwoLineElement.parse(
                name: nil, line1: testCase.line1, line2: testCase.line2
            ), let propagator = SGP4Propagator(tle: tle) else { continue }
            if propagator.isDeepSpace { deepSpace += 1 } else { nearEarth += 1 }
        }
        XCTAssertGreaterThanOrEqual(nearEarth, 3, "no near-Earth cases were exercised")
        XCTAssertGreaterThanOrEqual(deepSpace, 5, "no deep-space (SDP4) cases were exercised")
    }

    /// The deep-space branch is selected by orbital period, at 225 minutes.
    /// Getting this boundary wrong is the single most likely way to render a
    /// satellite with the wrong model, so it is pinned directly.
    func testDeepSpaceBranchIsSelectedByPeriod() throws {
        // 00005 is a 133-minute orbit; 20413 is a 24-hour one.
        let cases = Dictionary(
            uniqueKeysWithValues: Self.sgp4VerificationCases.map { ($0.catalogNumber, $0) }
        )
        for (catalogNumber, expectedDeepSpace) in [(5, false), (20413, true), (33335, true)] {
            guard let testCase = cases[catalogNumber],
                  let tle = TwoLineElement.parse(
                      name: nil, line1: testCase.line1, line2: testCase.line2
                  ),
                  let propagator = SGP4Propagator(tle: tle) else {
                XCTFail("missing case \(catalogNumber)"); continue
            }
            XCTAssertEqual(propagator.isDeepSpace, expectedDeepSpace,
                           "\(catalogNumber) took the wrong model branch")
            XCTAssertEqual(propagator.periodMinutes >= 225.0, expectedDeepSpace,
                           "\(catalogNumber): branch and period disagree")
        }
    }

    /// Propagating twice to the same time must give the same answer. This is
    /// not trivial: the deep-space resonance integrator carries state between
    /// calls specifically so that stepping forward is cheap, and a bug there
    /// would show up as a satellite whose position depends on how it was
    /// reached rather than on the time.
    func testRepeatedPropagationIsSelfConsistent() throws {
        guard let testCase = Self.sgp4VerificationCases.first(where: { $0.catalogNumber == 33335 }),
              let tle = TwoLineElement.parse(
                  name: nil, line1: testCase.line1, line2: testCase.line2
              ),
              var forward = SGP4Propagator(tle: tle),
              var direct = SGP4Propagator(tle: tle) else {
            return XCTFail("missing the geosynchronous verification case")
        }

        // One propagator walks there in small steps, the other jumps.
        var t = 0.0
        while t < 1440.0 {
            t += 30.0
            _ = try forward.propagate(minutesSinceEpoch: t)
        }
        let stepped = try forward.propagate(minutesSinceEpoch: 1440.0)
        let jumped = try direct.propagate(minutesSinceEpoch: 1440.0)
        XCTAssertLessThan(
            simd_distance(stepped.position, jumped.position), 0.001,
            "the resonance integrator's carried state changed the answer"
        )
    }

    /// The extrapolation the renderer relies on, measured rather than assumed.
    ///
    /// Between propagation ticks the render thread advances each satellite by
    /// `r + v * dt`. Two things make that inexact: the neglected quadratic
    /// (acceleration) term, and the fact that SGP4's reported velocity is the
    /// osculating two-body velocity rather than the exact time derivative of
    /// its own position function — the model does not differentiate its
    /// periodic terms. Both are small, but "small" is a claim worth checking.
    ///
    /// Measured across the verification set, the error over one 0.4-second tick
    /// is a few metres for ordinary orbits. At a typical viewing range that is
    /// on the order of 0.0003 degrees, roughly a hundredth of a pixel at a
    /// 90-degree field — comfortably invisible, which is the property the
    /// design depends on.
    ///
    /// The bound below is set by case 23333, an eccentricity-0.98 orbit checked
    /// near perigee where the acceleration is extreme. It is a deliberately
    /// hostile case and nothing like a real tracked satellite.
    func testLinearExtrapolationOverOneTickStaysBelowAPixel() throws {
        let tickSeconds = SatelliteTracker.tickInterval
        var worst = 0.0
        var worstOrdinary = 0.0

        for testCase in Self.sgp4VerificationCases {
            guard let tle = TwoLineElement.parse(
                name: nil, line1: testCase.line1, line2: testCase.line2
            ), var propagator = SGP4Propagator(tle: tle) else { continue }
            guard let baseMinutes = testCase.expected.first?.0 else { continue }

            guard let base = try? propagator.propagate(minutesSinceEpoch: baseMinutes),
                  let truth = try? propagator.propagate(
                      minutesSinceEpoch: baseMinutes + tickSeconds / 60.0
                  ) else { continue }

            let extrapolated = base.position + base.velocity * tickSeconds
            let error = simd_distance(extrapolated, truth.position)
            worst = max(worst, error)
            if tle.eccentricity < 0.25 { worstOrdinary = max(worstOrdinary, error) }
        }

        XCTAssertLessThan(worst, 0.2,
                          "extrapolation error over one tick reached \(worst) km")
        XCTAssertLessThan(worstOrdinary, 0.02,
                          "extrapolation error for ordinary orbits reached \(worstOrdinary) km")
        print("Extrapolation over \(tickSeconds) s: worst \(worst * 1000) m, "
              + "worst for near-circular orbits \(worstOrdinary * 1000) m")
    }
}

// MARK: - TLE parsing

final class TwoLineElementTests: XCTestCase {

    private let issLine1 = "1 25544U 98067A   26229.54791667  .00016717  00000-0  10270-3 0  9007"
    private let issLine2 = "2 25544  51.6416 247.4627 0006703 130.5360 325.0288 15.72125391563537"

    func testParsesEveryFieldOfARealElementSet() throws {
        guard let tle = TwoLineElement.parse(
            name: "ISS (ZARYA)", line1: issLine1, line2: issLine2
        ) else { return XCTFail("failed to parse") }

        XCTAssertEqual(tle.name, "ISS (ZARYA)")
        XCTAssertEqual(tle.catalogNumber, 25544)
        XCTAssertEqual(tle.internationalDesignator, "98067A")
        XCTAssertEqual(tle.epochYear, 26)
        XCTAssertEqual(tle.fullEpochYear, 2026)
        XCTAssertEqual(tle.epochDayOfYear, 229.54791667, accuracy: 1e-8)
        XCTAssertEqual(tle.inclinationDegrees, 51.6416, accuracy: 1e-6)
        XCTAssertEqual(tle.rightAscensionOfAscendingNodeDegrees, 247.4627, accuracy: 1e-6)
        XCTAssertEqual(tle.argumentOfPerigeeDegrees, 130.5360, accuracy: 1e-6)
        XCTAssertEqual(tle.meanAnomalyDegrees, 325.0288, accuracy: 1e-6)
        XCTAssertEqual(tle.meanMotionRevsPerDay, 15.72125391, accuracy: 1e-8)
        XCTAssertEqual(tle.revolutionNumber, 56353)
    }

    /// The eccentricity field has an implied leading decimal point: "0006703"
    /// is 0.0006703, not 6703.
    func testEccentricityHasAnImpliedDecimalPoint() throws {
        guard let tle = TwoLineElement.parse(
            name: nil, line1: issLine1, line2: issLine2
        ) else { return XCTFail("failed to parse") }
        XCTAssertEqual(tle.eccentricity, 0.0006703, accuracy: 1e-10)
    }

    /// `bstar` and `nddot` use the "modified exponential" encoding: " 10270-3"
    /// means 0.10270e-3. Getting this wrong is silent — the orbit still
    /// propagates, just with the wrong drag — so it is pinned explicitly.
    func testModifiedExponentialFieldsDecodeCorrectly() throws {
        guard let tle = TwoLineElement.parse(
            name: nil, line1: issLine1, line2: issLine2
        ) else { return XCTFail("failed to parse") }
        XCTAssertEqual(tle.bstar, 0.10270e-3, accuracy: 1e-12)
        XCTAssertEqual(tle.meanMotionDDot, 0.0, accuracy: 1e-16)
        XCTAssertEqual(tle.meanMotionDot, 0.00016717, accuracy: 1e-12)
    }

    /// A negative drag term, which real decaying-then-boosted objects carry.
    func testNegativeExponentialFieldDecodes() throws {
        let line1 = "1 02866U 67066E   26229.46029498 -.00000102  00000+0 -12345-4 0  9992"
        let line2 = "2 02866   2.7610  94.5741 0051400 214.4262  47.8747  1.09425939131702"
        guard let tle = TwoLineElement.parse(name: nil, line1: line1, line2: line2) else {
            return XCTFail("failed to parse")
        }
        XCTAssertEqual(tle.bstar, -0.12345e-4, accuracy: 1e-14)
        XCTAssertEqual(tle.meanMotionDot, -0.00000102, accuracy: 1e-14)
    }

    /// Alpha-5 catalog numbers: the leading digit becomes a letter once the
    /// catalogue passes 99999, with I and O skipped.
    func testAlpha5CatalogNumbersDecode() throws {
        let line1 = "1 A0001U 98067A   26229.54791667  .00016717  00000-0  10270-3 0  9007"
        let line2 = "2 A0001  51.6416 247.4627 0006703 130.5360 325.0288 15.72125391563537"
        guard let tle = TwoLineElement.parse(name: nil, line1: line1, line2: line2) else {
            return XCTFail("failed to parse")
        }
        XCTAssertEqual(tle.catalogNumber, 100_001)
    }

    /// Malformed records are skipped, not fatal: one bad line in a 16,000-entry
    /// catalogue must not cost the other 15,999.
    func testCatalogParsingSkipsMalformedRecords() throws {
        let text = """
        ISS (ZARYA)
        \(issLine1)
        \(issLine2)
        BROKEN SATELLITE
        1 this line is not an element set
        2 neither is this one
        ISS AGAIN
        \(issLine1)
        \(issLine2)
        """
        let elements = TwoLineElement.parseCatalog(text)
        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual(elements.first?.name, "ISS (ZARYA)")
        XCTAssertEqual(elements.last?.name, "ISS AGAIN")
    }

    /// The epoch conversion has to agree with the reference's own `jday`, since
    /// the verification vectors are stated relative to it. 2000 day 179.78495062
    /// is the epoch of verification case 00005.
    func testEpochJulianDayMatchesTheReferenceConvention() throws {
        let line1 = "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753"
        let line2 = "2 00005  34.2682 348.7242 1859667 331.7664  19.3264 10.82419157413667"
        guard let tle = TwoLineElement.parse(name: nil, line1: line1, line2: line2) else {
            return XCTFail("failed to parse")
        }
        // Days since 1949 Dec 31 00:00 UT, the quantity `sgp4init` takes.
        XCTAssertEqual(tle.sgp4Epoch, 18_441.78495062, accuracy: 1e-6)
        XCTAssertEqual(tle.epochJulianDay, 2_451_723.28495062, accuracy: 1e-6)
    }
}

// MARK: - Orbital regime classification

final class OrbitalRegimeTests: XCTestCase {

    func testClassifiesTheStandardRegimes() throws {
        // ISS: ~15.7 rev/day, near-circular.
        XCTAssertEqual(
            OrbitalRegime.classify(meanMotionRevsPerDay: 15.72, eccentricity: 0.0007),
            .lowEarth
        )
        // GPS: 2 rev/day.
        XCTAssertEqual(
            OrbitalRegime.classify(meanMotionRevsPerDay: 2.006, eccentricity: 0.01),
            .mediumEarth
        )
        // A geostationary comsat: one revolution per sidereal day.
        XCTAssertEqual(
            OrbitalRegime.classify(meanMotionRevsPerDay: 1.0027, eccentricity: 0.0002),
            .geosynchronous
        )
    }

    /// A Molniya orbit has a 12-hour period, which would read as MEO on mean
    /// motion alone. Eccentricity has to win, because a Molniya is nothing like
    /// a navigation satellite.
    func testHighEccentricityBeatsPeriod() throws {
        XCTAssertEqual(
            OrbitalRegime.classify(meanMotionRevsPerDay: 2.006, eccentricity: 0.74),
            .highlyElliptical
        )
    }
}

// MARK: - Topocentric transform

final class TopocentricTransformTests: XCTestCase {

    /// The observer vector must sit on the WGS-84 ellipsoid, not on a sphere.
    /// At the equator that means the equatorial radius exactly; at the pole it
    /// means the polar radius, 21.4 km smaller. A spherical Earth would put
    /// both at 6371 km and mis-point a 400 km target by degrees.
    func testObserverSitsOnTheWGS84Ellipsoid() throws {
        let jd = JulianDate.j2000

        let equator = TopocentricTransform.observerPositionTEME(
            observer: GeographicLocation(latitudeDegrees: 0, longitudeDegrees: 0), julianDay: jd
        )
        XCTAssertEqual(simd_length(equator), 6378.137, accuracy: 0.001)

        let pole = TopocentricTransform.observerPositionTEME(
            observer: GeographicLocation(latitudeDegrees: 90, longitudeDegrees: 0), julianDay: jd
        )
        let polarRadius = 6378.137 * (1.0 - TopocentricTransform.earthFlattening)
        XCTAssertEqual(simd_length(pole), polarRadius, accuracy: 0.001)
        XCTAssertEqual(simd_length(pole), 6356.752, accuracy: 0.01)
    }

    /// A satellite directly overhead reads as altitude 90, and its range is its
    /// height above the observer — the sanity check that the whole chain
    /// (observer vector, range vector, SEZ resolution) is wired the right way
    /// round.
    func testZenithSatelliteReadsAsAltitudeNinety() throws {
        let jd = 2_460_000.5
        let observer = GeographicLocation(latitudeDegrees: 37.5, longitudeDegrees: -122.0)
        let observerPosition = TopocentricTransform.observerPositionTEME(
            observer: observer, julianDay: jd
        )
        // 400 km straight up from the observer.
        let up = simd_normalize(observerPosition)
        let satellite = observerPosition + up * 400.0

        let look = TopocentricTransform.lookAngles(
            satellitePositionTEME: satellite, observer: observer, julianDay: jd
        )
        XCTAssertEqual(look.horizontal.altitudeDegrees, 90.0, accuracy: 0.5)
        XCTAssertEqual(look.rangeKilometres, 400.0, accuracy: 0.01)
    }

    /// Parallax is the whole reason satellites need their own transform. The
    /// same satellite seen from two places a few hundred kilometres apart must
    /// appear in genuinely different parts of the sky — for a star the same
    /// pair of observers would differ by microarcseconds.
    func testParallaxDominatesForNearObjects() throws {
        let jd = 2_460_000.5
        let here = GeographicLocation(latitudeDegrees: 37.5, longitudeDegrees: -122.0)
        let there = GeographicLocation(latitudeDegrees: 40.5, longitudeDegrees: -122.0)

        let overhead = TopocentricTransform.observerPositionTEME(observer: here, julianDay: jd)
        let satellite = overhead + simd_normalize(overhead) * 400.0

        let fromHere = TopocentricTransform.lookAngles(
            satellitePositionTEME: satellite, observer: here, julianDay: jd
        )
        let fromThere = TopocentricTransform.lookAngles(
            satellitePositionTEME: satellite, observer: there, julianDay: jd
        )

        XCTAssertEqual(fromHere.horizontal.altitudeDegrees, 90.0, accuracy: 0.5)
        // 3 degrees of latitude is ~333 km on the ground; against a 400 km
        // target that is most of the way to the horizon.
        XCTAssertLessThan(fromThere.horizontal.altitudeDegrees, 60.0)
        XCTAssertGreaterThan(fromThere.horizontal.altitudeDegrees, 20.0)
    }

    /// Azimuth follows the same convention as the rest of the app: measured
    /// from true north, increasing eastward.
    func testAzimuthIsMeasuredFromNorthEastward() throws {
        let jd = 2_460_000.5
        let observer = GeographicLocation(latitudeDegrees: 0, longitudeDegrees: 0)
        let observerPosition = TopocentricTransform.observerPositionTEME(
            observer: observer, julianDay: jd
        )
        // Push the satellite north of the observer: at the equator, +z is north.
        let up = simd_normalize(observerPosition)
        // North of the observer: at the equator, +z is due north.
        let north = TopocentricTransform.lookAngles(
            satellitePositionTEME: observerPosition + up * 800.0 + SIMD3(0.0, 0.0, 600.0),
            observer: observer, julianDay: jd
        )
        // Compared through the cosine so the 0/360 wrap cannot make an exactly
        // correct answer look like a 360-degree error.
        XCTAssertEqual(cos(Angle.degreesToRadians(north.horizontal.azimuthDegrees)),
                       1.0, accuracy: 0.001)

        // East of the observer: the local east direction at the equator is the
        // observer vector rotated a quarter turn about the polar axis.
        let east = simd_normalize(SIMD3(-up.y, up.x, 0.0))
        let toEast = TopocentricTransform.lookAngles(
            satellitePositionTEME: observerPosition + up * 800.0 + east * 600.0,
            observer: observer, julianDay: jd
        )
        XCTAssertEqual(toEast.horizontal.azimuthDegrees, 90.0, accuracy: 1.0)
    }

    /// Height above the ellipsoid, checked against the two axes where the
    /// answer is exact.
    func testHeightAboveEllipsoid() throws {
        let equatorial = SIMD3(6378.137 + 400.0, 0.0, 0.0)
        XCTAssertEqual(
            TopocentricTransform.heightAboveEllipsoid(geocentricPosition: equatorial),
            400.0, accuracy: 0.001
        )
        let polar = SIMD3(0.0, 0.0, 6356.752 + 400.0)
        XCTAssertEqual(
            TopocentricTransform.heightAboveEllipsoid(geocentricPosition: polar),
            400.0, accuracy: 0.5
        )
    }

    /// Round-tripping alt/az through the new equatorial inverse must return the
    /// same direction. This is the path a satellite's RA/Dec takes on the way
    /// to the info panel and to search's fly-to.
    func testHorizontalToEquatorialRoundTrips() throws {
        let jd = 2_460_123.456
        let observer = GeographicLocation(latitudeDegrees: 37.5, longitudeDegrees: -122.0)
        for (altitude, azimuth) in [(12.0, 45.0), (67.0, 210.0), (-30.0, 300.0), (85.0, 0.0)] {
            let horizontal = HorizontalCoordinate(
                altitudeDegrees: altitude, azimuthDegrees: azimuth
            )
            let equatorial = CoordinateTransformService.equatorial(
                from: horizontal, observer: observer, julianDay: jd
            )
            let back = CoordinateTransformService.horizontal(
                from: equatorial, observer: observer, julianDay: jd
            )
            XCTAssertEqual(back.altitudeDegrees, altitude, accuracy: 1e-6)
            XCTAssertEqual(back.azimuthDegrees, azimuth, accuracy: 1e-6)
        }
    }
}

// MARK: - Illumination

final class SatelliteIlluminationTests: XCTestCase {

    private let sunDistance = AstronomicalConstants.astronomicalUnitKilometres
    private let sunDirection = SIMD3(1.0, 0.0, 0.0)

    /// Anything on the sunward side of the Earth is lit, unconditionally.
    func testSunwardSideIsAlwaysSunlit() throws {
        let satellite = SIMD3(6778.0, 0.0, 0.0)
        XCTAssertEqual(
            TopocentricTransform.illumination(
                satellitePositionTEME: satellite,
                sunDirection: sunDirection, sunDistanceKm: sunDistance
            ),
            .sunlit
        )
    }

    /// Directly behind the Earth, on the shadow axis, is full umbra.
    func testDirectlyBehindTheEarthIsUmbral() throws {
        let satellite = SIMD3(-6778.0, 0.0, 0.0)
        XCTAssertEqual(
            TopocentricTransform.illumination(
                satellitePositionTEME: satellite,
                sunDirection: sunDirection, sunDistanceKm: sunDistance
            ),
            .umbra
        )
    }

    /// On the night side but well clear of the shadow cone: still lit. This is
    /// exactly the geometry of a satellite visible after sunset, which is the
    /// only time most satellites are visible at all.
    func testNightSideButOutsideTheShadowConeIsSunlit() throws {
        let satellite = SIMD3(-3000.0, 0.0, 8000.0)
        XCTAssertEqual(
            TopocentricTransform.illumination(
                satellitePositionTEME: satellite,
                sunDirection: sunDirection, sunDistanceKm: sunDistance
            ),
            .sunlit
        )
    }

    /// Grazing the shadow boundary produces penumbra, not a hard sunlit/umbral
    /// step. The band is narrow, which is why the search below is fine-grained.
    func testAPenumbralBandExistsAtTheShadowEdge() throws {
        var sawPenumbra = false
        var height = 6000.0
        while height < 6600.0 {
            let illumination = TopocentricTransform.illumination(
                satellitePositionTEME: SIMD3(-4000.0, 0.0, height),
                sunDirection: sunDirection, sunDistanceKm: sunDistance
            )
            if illumination == .penumbra { sawPenumbra = true; break }
            height += 1.0
        }
        XCTAssertTrue(sawPenumbra, "no penumbral band was found at the shadow edge")
    }

    /// The umbra is a cone, so it is narrower than the Earth at geostationary
    /// distance. A cylindrical model would call this point eclipsed; the cone
    /// correctly does not.
    func testUmbraNarrowsWithDistance() throws {
        // 42,164 km down-shadow, 6,300 km off-axis: inside a cylinder of the
        // Earth's radius, outside the real cone.
        let illumination = TopocentricTransform.illumination(
            satellitePositionTEME: SIMD3(-42_164.0, 0.0, 6_300.0),
            sunDirection: sunDirection, sunDistanceKm: sunDistance
        )
        XCTAssertNotEqual(illumination, .umbra)
    }
}

// MARK: - Snapshot lookup

final class SatelliteSnapshotTests: XCTestCase {

    private func sample(index: Int) -> SatelliteSample {
        SatelliteSample(
            index: index, catalogNumber: 10_000 + index, regime: .lowEarth, isNotable: false,
            epochJulianDay: JulianDate.j2000,
            position: SIMD3(7000, 0, 0), velocity: SIMD3(0, 7.5, 0),
            illumination: .sunlit, altitudeDegreesAtSnapshot: 45
        )
    }

    /// The binary search assumes the tracker emits samples in ascending index
    /// order, including when propagation failures leave gaps. Both properties
    /// are pinned here because a violation would silently return the wrong
    /// satellite's position to the info panel.
    func testFindsSamplesByDescriptorIndexAcrossGaps() throws {
        let indices = [0, 1, 5, 9, 40, 41, 900]
        let snapshot = SatelliteSnapshot(
            julianDay: 2_460_000.5,
            samples: indices.map(sample(index:)),
            propagationDuration: 0
        )
        for index in indices {
            XCTAssertEqual(snapshot.sample(descriptorIndex: index)?.index, index)
        }
        for missing in [2, 3, 8, 39, 42, 899, 901, -1] {
            XCTAssertNil(snapshot.sample(descriptorIndex: missing))
        }
    }
}

// MARK: - Rendering: level of detail

final class SatelliteRenderingTests: XCTestCase {

    /// A frame looking at the zenith from a fixed place and time, with a
    /// hand-built snapshot rather than a real catalogue.
    private func frame(
        samples: [SatelliteSample],
        descriptors: [SatelliteDescriptor],
        fieldOfView: Double,
        showAll: Bool
    ) -> SkyFrameData {
        var frame = SkyFrameData.empty
        frame.observerLocation = GeographicLocation(latitudeDegrees: 37.5, longitudeDegrees: -122.0)
        frame.julianDay = Self.julianDay
        frame.viewportSize = CGSize(width: 1600, height: 1000)
        frame.cameraCenter = HorizontalCoordinate(altitudeDegrees: 90, azimuthDegrees: 0)
        frame.cameraFieldOfViewDegrees = fieldOfView
        // Deep night, so nothing is suppressed by the daylight contrast model.
        frame.sunHorizontal = HorizontalCoordinate(altitudeDegrees: -40, azimuthDegrees: 0)
        frame.satelliteSnapshot = SatelliteSnapshot(
            julianDay: Self.julianDay, samples: samples, propagationDuration: 0
        )
        frame.satelliteDescriptors = descriptors
        frame.showAllSatellites = showAll
        return frame
    }

    private static let julianDay = 2_460_000.5

    /// A satellite 400 km directly above the observer.
    private func overheadPosition() -> SIMD3<Double> {
        let observer = TopocentricTransform.observerPositionTEME(
            observer: GeographicLocation(latitudeDegrees: 37.5, longitudeDegrees: -122.0),
            julianDay: Self.julianDay
        )
        return observer + simd_normalize(observer) * 400.0
    }

    private func descriptor(catalogNumber: Int, notable: Bool) -> SatelliteDescriptor {
        SatelliteDescriptor(
            catalogNumber: catalogNumber, name: "TEST \(catalogNumber)", regime: .lowEarth,
            internationalDesignator: "00001A", epochJulianDay: Self.julianDay - 1,
            isNotable: notable
        )
    }

    private func sample(
        index: Int, catalogNumber: Int, notable: Bool,
        illumination: TopocentricTransform.Illumination, altitude: Double
    ) -> SatelliteSample {
        SatelliteSample(
            index: index, catalogNumber: catalogNumber, regime: .lowEarth, isNotable: notable,
            epochJulianDay: Self.julianDay - 1,
            position: overheadPosition(), velocity: SIMD3(0, 7.5, 0),
            illumination: illumination, altitudeDegreesAtSnapshot: altitude
        )
    }

    private func drawnSatellites(_ frame: SkyFrameData) -> [ProjectedObject] {
        var builder = SkyGeometryBuilder(frameData: frame)
        builder.run()
        return builder.projectedObjects.filter { $0.object.kind == .satellite }
    }

    /// The default rule: a sunlit satellite above the horizon is drawn, because
    /// it is a thing you could actually go outside and see.
    func testSunlitOverheadSatelliteIsDrawnByDefault() throws {
        let drawn = drawnSatellites(frame(
            samples: [sample(index: 0, catalogNumber: 1, notable: false,
                             illumination: .sunlit, altitude: 89)],
            descriptors: [descriptor(catalogNumber: 1, notable: false)],
            fieldOfView: 90, showAll: false
        ))
        XCTAssertEqual(drawn.count, 1)
        XCTAssertEqual(drawn.first?.object.satelliteDetails?.catalogNumber, 1)
    }

    /// An eclipsed, unremarkable satellite is not drawn by default. This is the
    /// whole density story: without it the sky would carry sixteen thousand
    /// markers, most of them invisible in reality.
    func testEclipsedOrdinarySatelliteIsHiddenByDefault() throws {
        let drawn = drawnSatellites(frame(
            samples: [sample(index: 0, catalogNumber: 1, notable: false,
                             illumination: .umbra, altitude: 89)],
            descriptors: [descriptor(catalogNumber: 1, notable: false)],
            fieldOfView: 90, showAll: false
        ))
        XCTAssertTrue(drawn.isEmpty)
    }

    /// A notable object is always drawn, sunlit or not, so "where is the ISS
    /// right now" always has an answer.
    func testNotableSatelliteIsDrawnEvenWhenEclipsed() throws {
        let drawn = drawnSatellites(frame(
            samples: [sample(index: 0, catalogNumber: 25544, notable: true,
                             illumination: .umbra, altitude: 89)],
            descriptors: [descriptor(catalogNumber: 25544, notable: true)],
            fieldOfView: 90, showAll: false
        ))
        XCTAssertEqual(drawn.count, 1)
        XCTAssertEqual(drawn.first?.object.satelliteDetails?.illumination, .umbra)
    }

    /// "Show all" reveals the long tail, but only once zoomed in — at a
    /// whole-sky field it stays quiet.
    func testShowAllRevealsTheTailOnlyWhenZoomedIn() throws {
        let samples = [sample(index: 0, catalogNumber: 1, notable: false,
                              illumination: .umbra, altitude: 89)]
        let descriptors = [descriptor(catalogNumber: 1, notable: false)]

        let wide = drawnSatellites(frame(
            samples: samples, descriptors: descriptors, fieldOfView: 140, showAll: true
        ))
        XCTAssertTrue(wide.isEmpty, "the tail should stay hidden at a whole-sky field")

        let zoomed = drawnSatellites(frame(
            samples: samples, descriptors: descriptors, fieldOfView: 20, showAll: true
        ))
        XCTAssertEqual(zoomed.count, 1, "the tail should appear once zoomed in")
    }

    /// The layer's master switch really does switch everything off, notable
    /// objects included.
    func testDisablingTheLayerHidesEvenNotableSatellites() throws {
        var data = frame(
            samples: [sample(index: 0, catalogNumber: 25544, notable: true,
                             illumination: .sunlit, altitude: 89)],
            descriptors: [descriptor(catalogNumber: 25544, notable: true)],
            fieldOfView: 90, showAll: false
        )
        data.satellitesEnabled = false
        XCTAssertTrue(drawnSatellites(data).isEmpty)
    }

    /// The drawn position must come from the extrapolated state, not from the
    /// snapshot. Advancing the frame's clock past the snapshot's without
    /// re-propagating has to move the satellite — that motion *is* the smooth
    /// rendering, so its absence would mean satellites visibly stepping once
    /// per tick.
    func testDrawnPositionAdvancesBetweenPropagationTicks() throws {
        let samples = [sample(index: 0, catalogNumber: 1, notable: true,
                              illumination: .sunlit, altitude: 89)]
        let descriptors = [descriptor(catalogNumber: 1, notable: true)]

        var atTick = frame(samples: samples, descriptors: descriptors,
                           fieldOfView: 30, showAll: false)
        var laterFrame = atTick
        // A third of a second later, with the same snapshot.
        laterFrame.julianDay = Self.julianDay + 0.33 / 86_400.0

        guard let first = drawnSatellites(atTick).first,
              let second = drawnSatellites(laterFrame).first else {
            return XCTFail("the satellite was not drawn")
        }
        let moved = simd_distance(first.ndcPosition, second.ndcPosition)
        XCTAssertGreaterThan(moved, 1e-5, "the satellite did not move between ticks")

        // And the motion is smooth, not a jump: a third of a second of a 7.5
        // km/s orbit seen from 400 km is a fraction of the field, never a leap
        // across it.
        XCTAssertLessThan(moved, 0.5)
        _ = atTick
    }
}

// MARK: - Graduated element-set staleness

/// The regression the user hit, and the rule that replaced it.
///
/// Satellites disappeared because the bundled element sets aged past a hard
/// five-day cutoff while the daily refresh — one source, one attempt per launch
/// — had never once succeeded. The cutoff was right about the time machine and
/// wrong about the live sky: at real time, week-old elements still tell you
/// which moving dot is the ISS, provided the app says how good the answer is.
final class ElementSetStalenessTests: XCTestCase {

    // MARK: Classification

    func testFreshElementsAreNotFlagged() {
        XCTAssertEqual(SatelliteAccuracy.staleness(ageDays: 0), .fresh)
        XCTAssertEqual(SatelliteAccuracy.staleness(ageDays: 1.9), .fresh)
        XCTAssertEqual(SatelliteAccuracy.staleness(ageDays: 2.0), .fresh)
        XCTAssertNil(ElementSetStaleness.fresh.caveat)
        XCTAssertNil(ElementSetStaleness.fresh.shortLabel)
    }

    func testAgingElementsCarryACaveat() {
        XCTAssertEqual(SatelliteAccuracy.staleness(ageDays: 2.1), .aging)
        XCTAssertEqual(SatelliteAccuracy.staleness(ageDays: 7.7), .aging)
        XCTAssertEqual(SatelliteAccuracy.staleness(ageDays: 10.0), .aging)
        XCTAssertNotNil(ElementSetStaleness.aging.caveat)
        XCTAssertEqual(ElementSetStaleness.aging.shortLabel, "aging")
    }

    func testVeryOldElementsAreFlaggedUnreliable() {
        XCTAssertEqual(SatelliteAccuracy.staleness(ageDays: 10.1), .unreliable)
        XCTAssertEqual(SatelliteAccuracy.staleness(ageDays: 90), .unreliable)
        XCTAssertNotNil(ElementSetStaleness.unreliable.caveat)
        XCTAssertEqual(ElementSetStaleness.unreliable.shortLabel, "unreliable")
    }

    /// Elements dated *after* the displayed instant are exactly as approximate
    /// as ones the same distance before it.
    func testClassificationIsSymmetric() {
        XCTAssertEqual(SatelliteAccuracy.staleness(ageDays: -7.0), .aging)
        XCTAssertEqual(SatelliteAccuracy.staleness(ageDays: -30.0), .unreliable)
    }

    func testSeverityIsOrdered() {
        XCTAssertLessThan(ElementSetStaleness.fresh, .aging)
        XCTAssertLessThan(ElementSetStaleness.aging, .unreliable)
    }

    // MARK: The gate itself

    private let now = 2_460_500.5

    /// **The user's bug.** At real time, elements older than the old five-day
    /// cutoff must still be drawn.
    func testAgingElementsAreStillDrawnAtRealTime() {
        for age in [5.1, 7.7, 12.0, 40.0] {
            XCTAssertTrue(
                SatelliteAccuracy.isDrawable(
                    julianDay: now, nowJulianDay: now, epochJulianDay: now - age
                ),
                "\(age)-day-old elements must not hide the live sky"
            )
        }
    }

    /// **The rule that must not be lost.** Scrubbing simulated time far from
    /// both real time and the epoch draws nothing: an SGP4 propagation that far
    /// out is not an imprecise position, it is no position at all.
    func testFarSimulatedTimeIsStillSuppressed() {
        let epoch = now - 1.0
        for offset in [6.0, 30.0, 365.0, -30.0] {
            XCTAssertFalse(
                SatelliteAccuracy.isDrawable(
                    julianDay: now + offset, nowJulianDay: now, epochJulianDay: epoch
                ),
                "scrubbing \(offset) days out must draw nothing"
            )
        }
    }

    /// A short scrub with fresh elements is still fine, which is what makes
    /// "watch tonight's pass an hour early" work.
    func testShortScrubsWithFreshElementsAreDrawn() {
        XCTAssertTrue(
            SatelliteAccuracy.isDrawable(
                julianDay: now + 2.0, nowJulianDay: now, epochJulianDay: now
            )
        )
        XCTAssertTrue(
            SatelliteAccuracy.isDrawable(
                julianDay: now + 40.0, nowJulianDay: now, epochJulianDay: now + 38.0
            ),
            "elements near the displayed instant are valid wherever that instant is"
        )
    }
}

// MARK: - Satellites at the age the app actually ships with

/// End-to-end version of the regression: a frame at real time whose elements
/// are as old as the bundled snapshot had become must still draw its satellite.
final class BundledElementAgeRenderingTests: XCTestCase {

    private func drawnCount(elementAgeDays: Double, simulatedOffsetDays: Double = 0) -> Int {
        let now = JulianDate.julianDay(from: Date())
        let julianDay = now + simulatedOffsetDays
        var frame = SkyFrameData.empty
        frame.observerLocation = GeographicLocation(latitudeDegrees: 37.5, longitudeDegrees: -122.0)
        frame.julianDay = julianDay
        frame.nowJulianDay = now
        frame.viewportSize = CGSize(width: 1600, height: 1000)
        frame.cameraCenter = HorizontalCoordinate(altitudeDegrees: 90, azimuthDegrees: 0)
        frame.cameraFieldOfViewDegrees = 90
        frame.sunHorizontal = HorizontalCoordinate(altitudeDegrees: -40, azimuthDegrees: 0)

        let observer = TopocentricTransform.observerPositionTEME(
            observer: frame.observerLocation, julianDay: julianDay
        )
        let position = observer + simd_normalize(observer) * 400.0
        let epoch = julianDay - elementAgeDays

        frame.satelliteSnapshot = SatelliteSnapshot(
            julianDay: julianDay,
            samples: [
                SatelliteSample(
                    index: 0, catalogNumber: Satellite.issCatalogNumber,
                    regime: .lowEarth, isNotable: true, epochJulianDay: epoch,
                    position: position, velocity: SIMD3(0, 7.5, 0),
                    illumination: .sunlit, altitudeDegreesAtSnapshot: 89
                )
            ],
            propagationDuration: 0
        )
        frame.satelliteDescriptors = [
            SatelliteDescriptor(
                catalogNumber: Satellite.issCatalogNumber, name: "ISS (ZARYA)",
                regime: .lowEarth, internationalDesignator: "98067A",
                epochJulianDay: epoch, isNotable: true
            )
        ]
        var builder = SkyGeometryBuilder(frameData: frame)
        builder.run()
        return builder.projectedObjects.filter { $0.object.kind == .satellite }.count
    }

    /// Eight days is roughly how stale the shipped snapshot had become when the
    /// user reported the satellites missing. It must draw.
    func testSatellitesAreDrawnAtTheShippedElementAge() {
        XCTAssertEqual(drawnCount(elementAgeDays: 8.0), 1)
        XCTAssertEqual(drawnCount(elementAgeDays: 20.0), 1, "old, but the sky is live")
    }

    /// And the time machine still refuses.
    func testTheTimeMachineStillSuppresses() {
        XCTAssertEqual(drawnCount(elementAgeDays: 8.0, simulatedOffsetDays: 30.0), 0)
        XCTAssertEqual(drawnCount(elementAgeDays: 8.0, simulatedOffsetDays: -60.0), 0)
    }
}

// MARK: - Fallback source parsing

final class SatelliteFallbackSourceTests: XCTestCase {

    /// SatNOGS serves JSON, with the name line in the NASA "0 NAME" form. It
    /// has to come out the other side as text the normal TLE parser accepts.
    func testSatnogsJSONBecomesParseableTLEText() throws {
        let json = """
        [{"tle0":"0 ISS (ZARYA)",
          "tle1":"1 25544U 98067A   26237.66055539  .00007716  00000-0  14485-3 0  9995",
          "tle2":"2 25544  51.6329 316.2335 0007673  83.1052 277.0809 15.49625410582525"}]
        """
        let text = try SatelliteCatalogService.tleText(fromSatnogsJSON: Data(json.utf8))
        let elements = TwoLineElement.parseCatalog(text)
        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements.first?.catalogNumber, 25544)
        XCTAssertEqual(elements.first?.name, "ISS (ZARYA)")
        XCTAssertNotNil(Satellite(tle: try XCTUnwrap(elements.first)))
    }

    /// A partial fallback source must never cost the user the rest of the
    /// catalogue: it is overlaid onto the full one, and only where it is newer.
    func testOverlayKeepsTheFullCatalogueAndTakesOnlyFresherElements() throws {
        let base = TwoLineElement.parseCatalog("""
        ISS (ZARYA)
        1 25544U 98067A   26229.66055539  .00007716  00000-0  14485-3 0  9995
        2 25544  51.6329 316.2335 0007673  83.1052 277.0809 15.49625410582525
        CALSPHERE 1
        1 00900U 64063C   26229.88451900  .00000398  00000+0  39512-3 0  9996
        2 00900  90.2179  73.2057 0027808 103.8625   3.2515 13.76679677 79914
        """)
        let supplement = TwoLineElement.parseCatalog("""
        ISS (ZARYA)
        1 25544U 98067A   26237.66055539  .00007716  00000-0  14485-3 0  9995
        2 25544  51.6329 316.2335 0007673  83.1052 277.0809 15.49625410582525
        """)
        XCTAssertEqual(base.count, 2)
        XCTAssertEqual(supplement.count, 1)

        let merged = SatelliteCatalogService.overlay(supplement: supplement, onto: base)
        XCTAssertEqual(merged.count, 2, "the object the supplement does not carry must survive")
        let iss = try XCTUnwrap(merged.first { $0.catalogNumber == 25544 })
        XCTAssertEqual(iss.epochJulianDay, supplement[0].epochJulianDay, accuracy: 1e-9,
                       "the fresher element set must win")

        // And the other way round: a stale supplement must not drag anything
        // backwards.
        let reversed = SatelliteCatalogService.overlay(supplement: base, onto: merged)
        let stillFresh = try XCTUnwrap(reversed.first { $0.catalogNumber == 25544 })
        XCTAssertEqual(stillFresh.epochJulianDay, supplement[0].epochJulianDay, accuracy: 1e-9)
    }
}
