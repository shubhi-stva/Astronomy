//
//  ApparentPlaceTests.swift
//  AstronomyTests
//
//  The pieces of the apparent-place reduction, each against a published value
//  or an independent property: ΔT, nutation, aberration, refraction, the
//  equation of the equinoxes, and the IAU constellation boundaries.
//
//  `HorizonsAccuracyTests` checks the whole chain end to end against JPL. This
//  file checks the parts, so a regression says *which* part.
//

import XCTest
import simd
@testable import Astronomy

// MARK: - ΔT

final class DeltaTTests: XCTestCase {

    /// Observed values (IERS / the Astronomical Almanac). The 2020s matter
    /// most: that is where the app is used, and a wrong ΔT there moves the
    /// Moon by tens of arcseconds.
    func testMatchesTheObservedRecord() {
        let published: [(year: Double, seconds: Double)] = [
            (1900.0, -2.8), (1950.0, 29.1), (1970.0, 40.2), (1990.0, 56.9),
            (2000.0, 63.8), (2010.0, 66.1), (2020.0, 69.4), (2026.0, 69.2),
        ]
        for (year, expected) in published {
            XCTAssertEqual(
                DeltaT.seconds(decimalYear: year), expected, accuracy: 1.5,
                "ΔT at \(year)"
            )
        }
    }

    /// Continuous across every branch boundary: a step would make the sky jump
    /// as the time machine crossed it.
    func testIsContinuousAcrossItsBranches() {
        for boundary in [1600.0, 1700.0, 1800.0, 1860.0, 1900.0, 1920.0, 1941.0,
                         1961.0, 1986.0, 2000.0, 2027.0] {
            let before = DeltaT.seconds(decimalYear: boundary - 1e-6)
            let after = DeltaT.seconds(decimalYear: boundary + 1e-6)
            XCTAssertEqual(
                before, after, accuracy: 1.0,
                "ΔT steps by \(after - before) s at \(boundary)"
            )
        }
    }

    /// TT runs ahead of UT, and the conversion is the one the ephemerides use.
    func testTerrestrialTimeIsAheadOfUniversalTime() {
        let jd = 2_461_055.5
        let tt = DeltaT.terrestrialJulianDay(fromUniversal: jd)
        XCTAssertGreaterThan(tt, jd)
        // Loose only because of the subtraction: a Julian Day is ~2.46e6, so
        // `tt - jd` throws away most of a double's precision before the
        // multiplication puts it back. The quantity itself is exact.
        XCTAssertEqual((tt - jd) * 86_400, DeltaT.seconds(julianDay: jd), accuracy: 1e-4)
    }
}

// MARK: - Nutation

final class NutationTests: XCTestCase {

    /// Meeus, *Astronomical Algorithms*, 2nd ed., Example 22.a: 1987 April 10
    /// at 0h TD (JDE 2446895.5) gives Δψ = −3.788″, Δε = +9.443″ and
    /// ε₀ = 23° 26′ 27.407″. The abridged series is quoted to 0.5″ in Δψ and
    /// 0.1″ in Δε, which is the tolerance used here.
    func testReproducesMeeusExample22a() {
        let angles = Nutation.angles(julianDayTT: 2_446_895.5)
        XCTAssertEqual(angles.deltaPsiDegrees * 3600, -3.788, accuracy: 0.5)
        XCTAssertEqual(angles.deltaEpsilonDegrees * 3600, 9.443, accuracy: 0.1)
        XCTAssertEqual(
            angles.meanObliquityDegrees, 23 + 26.0 / 60 + 27.407 / 3600, accuracy: 0.5 / 3600
        )
    }

    /// The obliquity at J2000.0 is 23° 26′ 21.448″ by construction.
    func testObliquityAtJ2000() {
        XCTAssertEqual(
            Nutation.meanObliquityDegrees(julianCenturies: 0),
            23 + 26.0 / 60 + 21.448 / 3600,
            accuracy: 1e-9
        )
    }

    /// The equation of the equinoxes is Δψ cos ε, and it is what separates
    /// mean from apparent sidereal time. Up to about 1.1 seconds of time.
    func testEquationOfTheEquinoxesIsSmallButNotZero() {
        let jd = 2_461_055.5
        let angles = Nutation.angles(julianDayTT: jd)
        let expected = angles.deltaPsiDegrees
            * cos(Angle.degreesToRadians(angles.trueObliquityDegrees))
        XCTAssertEqual(angles.equationOfEquinoxesDegrees, expected, accuracy: 1e-12)

        let mean = CoordinateTransformService.greenwichMeanSiderealTimeDegrees(julianDay: jd)
        let apparent = CoordinateTransformService.greenwichApparentSiderealTimeDegrees(julianDay: jd)
        var difference = apparent - mean
        if difference > 180 { difference -= 360 }
        if difference < -180 { difference += 360 }
        // 1.1 s of time is 0.00458 degrees.
        XCTAssertLessThan(abs(difference), 0.005)
        XCTAssertGreaterThan(abs(difference), 1e-6)
    }

    /// The nutation rotation must be a rotation: orthonormal, determinant +1,
    /// and a small one — it is a wobble of arcseconds, not a reorientation.
    func testTheRotationIsOrthonormalAndSmall() {
        let angles = Nutation.angles(julianDayTT: 2_461_055.5)
        let matrix = Nutation.rotationMatrix(angles: angles)
        let product = matrix.transpose * matrix
        for row in 0..<3 {
            for column in 0..<3 {
                XCTAssertEqual(
                    product[column][row], row == column ? 1 : 0, accuracy: 1e-12
                )
            }
        }
        XCTAssertEqual(matrix.determinant, 1.0, accuracy: 1e-12)

        // An arbitrary direction moves by well under an arcminute.
        let v = simd_normalize(SIMD3(0.3, 0.6, 0.74))
        let moved = matrix * v
        let separation = Angle.radiansToDegrees(
            atan2(simd_length(simd_cross(v, moved)), simd_dot(v, moved))
        ) * 3600
        XCTAssertLessThan(separation, 30)
        XCTAssertGreaterThan(separation, 0.5)
    }
}

// MARK: - Aberration

final class AberrationTests: XCTestCase {

    /// The constant of aberration is 20.49551″: the Earth's orbital speed
    /// divided by the speed of light. It falls out of the VSOP87 velocity
    /// rather than being written down anywhere, which is what this checks.
    func testTheConstantOfAberrationComesOutOfTheEarthsVelocity() {
        for jd in [2_451_545.0, 2_461_055.5, 2_470_000.0] {
            let earth = EarthState(julianDayUT: jd)
            let kappa = Angle.radiansToDegrees(simd_length(earth.velocityOverLight)) * 3600
            XCTAssertEqual(kappa, 20.4955, accuracy: 0.35, "aberration constant at \(jd)")
        }
    }

    /// Applying aberration displaces a star by at most the constant, and
    /// toward the apex of the Earth's motion. A star *at* the apex is
    /// undisplaced, which is the property that distinguishes the real
    /// first-order formula from a constant nudge.
    func testDisplacementIsZeroTowardTheApexAndMaximalAtRightAngles() {
        let frame = ApparentFrame(julianDayUT: 2_461_055.5)
        let apex = simd_normalize(frame.aberration)

        func displacementArcseconds(_ direction: SIMD3<Double>) -> Double {
            let moved = simd_normalize(direction + frame.aberration)
            return Angle.radiansToDegrees(
                atan2(simd_length(simd_cross(direction, moved)), simd_dot(direction, moved))
            ) * 3600
        }

        XCTAssertLessThan(displacementArcseconds(apex), 0.01)

        // Any direction perpendicular to the apex gets the full constant.
        var perpendicular = simd_cross(apex, SIMD3(0, 0, 1))
        XCTAssertGreaterThan(simd_length(perpendicular), 1e-6)
        perpendicular = simd_normalize(perpendicular)
        XCTAssertEqual(displacementArcseconds(perpendicular), 20.5, accuracy: 0.5)
    }

    /// The reduction a catalogue star goes through must equal the one the
    /// projector applies, or search would centre the camera somewhere other
    /// than where the star is drawn.
    func testTheProjectorAgreesWithTheOneOffReduction() {
        let jd = 2_461_055.5
        var frame = SkyFrameData.empty
        frame.observerLocation = GeographicLocation(latitudeDegrees: 37.77, longitudeDegrees: -122.42)
        frame.julianDay = jd
        frame.cameraCenter = HorizontalCoordinate(altitudeDegrees: 50, azimuthDegrees: 120)
        frame.cameraFieldOfViewDegrees = 30
        frame.viewportSize = CGSize(width: 1000, height: 800)
        frame.refractionEnabled = false
        let apparentFrame = ApparentFrame(julianDayUT: jd)
        let projector = SkyProjector(frameData: frame, apparentFrame: apparentFrame)

        for (ra, dec) in [(101.3, -16.7), (0.0, 89.0), (280.0, 38.8), (200.0, -60.0)] {
            let catalogue = EquatorialCoordinate(rightAscensionDegrees: ra, declinationDegrees: dec)
            // Through the projector: reduced, then to alt/az.
            let viaProjector = projector.horizontal(direction: projector.direction(j2000: catalogue))
            // One-off: reduced to an apparent place, then the ordinary transform.
            let apparent = apparentFrame.apparent(j2000: catalogue)
            let viaTransform = CoordinateTransformService.horizontal(
                from: apparent, observer: frame.observerLocation, julianDay: jd
            )
            XCTAssertEqual(
                viaProjector.altitudeDegrees, viaTransform.altitudeDegrees, accuracy: 1e-9,
                "altitude at \(ra), \(dec)"
            )
            var delta = viaProjector.azimuthDegrees - viaTransform.azimuthDegrees
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            XCTAssertEqual(delta, 0, accuracy: 1e-9, "azimuth at \(ra), \(dec)")
        }
    }
}

// MARK: - Refraction

final class RefractionTests: XCTestCase {

    /// Published values for a standard atmosphere: about 34′ at the horizon,
    /// 5.3′ at 10°, 1.7′ at 30°, and nothing at the zenith.
    func testMatchesPublishedValues() {
        XCTAssertEqual(Refraction.refractionDegrees(trueAltitudeDegrees: 0) * 60, 28.8, accuracy: 1.0)
        XCTAssertEqual(Refraction.refractionDegrees(trueAltitudeDegrees: 10) * 60, 5.3, accuracy: 0.3)
        XCTAssertEqual(Refraction.refractionDegrees(trueAltitudeDegrees: 30) * 60, 1.7, accuracy: 0.1)
        XCTAssertEqual(Refraction.refractionDegrees(trueAltitudeDegrees: 90) * 60, 0.0, accuracy: 0.01)
    }

    /// It only ever lifts, it shrinks with altitude, and it fades out below
    /// the horizon rather than stepping — the see-through-Earth view is not a
    /// sightline through air.
    func testIsMonotonicNonNegativeAndFadesBelowTheHorizon() {
        var previous = Double.infinity
        for altitude in stride(from: 0.0, through: 90.0, by: 0.5) {
            let refraction = Refraction.refractionDegrees(trueAltitudeDegrees: altitude)
            XCTAssertGreaterThanOrEqual(refraction, 0)
            XCTAssertLessThanOrEqual(refraction, previous + 1e-12)
            previous = refraction
        }
        XCTAssertEqual(Refraction.refractionDegrees(trueAltitudeDegrees: -5), 0, accuracy: 1e-12)
        XCTAssertGreaterThan(Refraction.refractionDegrees(trueAltitudeDegrees: -0.5), 0)
    }

    /// Inverting the correction returns the true altitude.
    func testTrueAndApparentAltitudesRoundTrip() {
        for altitude in stride(from: -0.5, through: 89.0, by: 1.0) {
            let apparent = Refraction.apparentAltitudeDegrees(trueAltitudeDegrees: altitude)
            let back = Refraction.trueAltitudeDegrees(apparentAltitudeDegrees: apparent)
            XCTAssertEqual(back, altitude, accuracy: 1e-6, "round trip at \(altitude)")
        }
    }

    /// The table the renderer uses must agree with the formula it tabulates,
    /// keep its vectors unit, and leave the azimuth alone.
    func testTheLookupTableAgreesWithTheFormula() {
        let table = Refraction.Table.shared
        var worst = 0.0
        for altitude in stride(from: -0.5, through: 89.5, by: 0.25) {
            for azimuth in [0.0, 73.0, 201.0, 315.0] {
                let horizontal = HorizontalCoordinate(
                    altitudeDegrees: altitude, azimuthDegrees: azimuth
                )
                let direction = CoordinateTransformService.unitDirection(fromHorizontal: horizontal)
                let lifted = table.apparent(direction: direction)

                // The table interpolates sin(h') and the horizontal rescaling
                // independently, so a unit vector comes back unit to about a
                // part in 10^8 rather than exactly — two milli-arcseconds of
                // direction, which nothing downstream can see.
                XCTAssertEqual(simd_length(lifted), 1.0, accuracy: 1e-7)

                let liftedAltitude = Angle.radiansToDegrees(asin(max(-1, min(1, lifted.y))))
                let expected = Refraction.apparentAltitudeDegrees(trueAltitudeDegrees: altitude)
                worst = max(worst, abs(liftedAltitude - expected) * 3600)

                let liftedAzimuth = Angle.normalizeDegrees(
                    Angle.radiansToDegrees(atan2(lifted.x, -lifted.z))
                )
                var delta = liftedAzimuth - azimuth
                if delta > 180 { delta -= 360 }
                if delta < -180 { delta += 360 }
                XCTAssertEqual(delta, 0, accuracy: 1e-6, "refraction moved the azimuth")
            }
        }
        // The interpolation error is worst at the horizon, where refraction
        // changes fastest; a tenth of a pixel at the narrowest field is 0.036″.
        XCTAssertLessThan(worst, 1.0, "table interpolation is off by \(worst)″")
    }

    /// Sunset is *defined* with refraction in it — the −0.8333° standard
    /// altitude is the refracted upper limb — so the drawn Sun must be at or
    /// above the horizon at the moment the app says the Sun sets. Before
    /// refraction was drawn, the time bar said "sunset" with the disk most of
    /// a degree below the skyline.
    func testTheSunIsAtTheHorizonWhenTheAppSaysItSets() {
        let observer = GeographicLocation(latitudeDegrees: 37.77, longitudeDegrees: -122.42)
        let start = 2_461_055.0
        let events = RiseSetCalculator.sunEvents(observer: observer, startJulianDay: start)
        guard let set = events.setJulianDay else {
            return XCTFail("no sunset on a day that has one")
        }
        let sun = EphemerisService.solarSystemObjects(julianDay: set, observer: observer)
            .first { $0.id == "sun" }!
        let geometric = CoordinateTransformService.horizontal(
            from: sun.equatorial, observer: observer, julianDay: set
        )
        XCTAssertEqual(geometric.altitudeDegrees, -0.8333, accuracy: 0.05)

        // Refracted, the centre sits a little under a semidiameter below the
        // horizon — which is exactly what "the upper limb is on the horizon"
        // means, and is what the renderer now draws.
        let apparent = Refraction.apparentAltitudeDegrees(
            trueAltitudeDegrees: geometric.altitudeDegrees
        )
        XCTAssertEqual(apparent, -0.27, accuracy: 0.1)
    }
}

// MARK: - Constellation boundaries

final class ConstellationBoundaryTests: XCTestCase {

    private static let boundaries: ConstellationBoundaries? = {
        guard let url = Bundle.main.url(
                  forResource: "constellation_boundaries", withExtension: "json"
              ),
              let data = try? Data(contentsOf: url),
              let edges = try? JSONDecoder().decode([ConstellationBoundaryEdge].self, from: data)
        else { return nil }
        return ConstellationBoundaries(edges: edges)
    }()

    func testTheBundledTableIsComplete() throws {
        let boundaries = try XCTUnwrap(Self.boundaries, "boundary table unavailable in this bundle")
        // Delporte's 781 edges over 89 regions: 88 constellations, with
        // Serpens in its two traditional halves.
        XCTAssertEqual(boundaries.edges.count, 781)
        XCTAssertEqual(boundaries.abbreviations.count, 89)
        XCTAssertEqual(
            Set(boundaries.abbreviations.map(ConstellationBoundaries.displayAbbreviation)).count, 88
        )
        // Every edge is a meridian or a parallel *in B1875*. That is what
        // makes the region test exact, so it is worth asserting rather than
        // assuming.
        for edge in boundaries.edges {
            if edge.isMeridian {
                XCTAssertEqual(edge.rightAscension1, edge.rightAscension2, accuracy: 1e-6)
            } else {
                XCTAssertEqual(edge.declination1, edge.declination2, accuracy: 1e-6)
            }
        }
    }

    /// Known positions, checked against the constellation every catalogue
    /// agrees they are in.
    func testWellKnownObjectsLandInTheRightConstellation() throws {
        let boundaries = try XCTUnwrap(Self.boundaries, "boundary table unavailable in this bundle")
        let cases: [(name: String, ra: Double, dec: Double, constellation: String)] = [
            ("Sirius", 101.287, -16.716, "CMa"),
            ("Betelgeuse", 88.793, 7.407, "Ori"),
            ("Vega", 279.234, 38.784, "Lyr"),
            ("Polaris", 37.955, 89.264, "UMi"),
            ("M31", 10.685, 41.269, "And"),
            ("M42", 83.822, -5.391, "Ori"),
            ("Antares", 247.352, -26.432, "Sco"),
            ("Alpha Centauri", 219.902, -60.834, "Cen"),
            ("M13", 250.423, 36.460, "Her"),
            ("Fomalhaut", 344.413, -29.622, "PsA"),
            ("Sigma Octantis", 317.195, -88.956, "Oct"),
            ("Barnard's Star", 269.452, 4.693, "Oph"),
            // Both halves of Serpens answer "Ser", which is the name of the
            // constellation they are two pieces of.
            ("Unukalhai (Caput)", 236.067, 6.426, "Ser"),
            ("Eta Serpentis (Cauda)", 275.328, -2.898, "Ser"),
            // Just inside the RA seam, north and south: the case the previous
            // implementation got wrong across most of the sky.
            ("Alpheratz", 2.097, 29.090, "And"),
            ("Deneb Kaitos", 10.897, -17.987, "Cet"),
        ]
        for testCase in cases {
            let found = boundaries.constellation(
                containing: EquatorialCoordinate(
                    rightAscensionDegrees: testCase.ra, declinationDegrees: testCase.dec
                )
            )
            XCTAssertEqual(found, testCase.constellation, testCase.name)
        }
    }

    /// Every point on the sky is in exactly one region. Sampled over a grid,
    /// which is the property that catches a wrong winding or a mishandled
    /// pole — those show up as gaps or as overlaps.
    func testEveryDirectionBelongsToExactlyOneConstellation() throws {
        let boundaries = try XCTUnwrap(Self.boundaries, "boundary table unavailable in this bundle")
        let abbreviations = boundaries.abbreviations
        var checked = 0
        for raStep in 0..<72 {
            for decStep in 0...36 {
                let ra = Double(raStep) * 5.0 + 2.37
                let dec = -90.0 + Double(decStep) * 5.0 + 0.61
                guard dec < 90 else { continue }
                // In B1875, where the edges are straight and the test is exact.
                let point = boundaries.b1875(
                    fromJ2000: EquatorialCoordinate(
                        rightAscensionDegrees: ra, declinationDegrees: dec
                    )
                )
                let matches = abbreviations.filter {
                    boundaries.contains(
                        abbreviation: $0,
                        rightAscension: Angle.normalizeDegrees(point.rightAscensionDegrees),
                        declination: point.declinationDegrees
                    )
                }
                XCTAssertEqual(matches.count, 1, "ra \(ra) dec \(dec) is in \(matches)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 2000)
    }

    /// The boundaries are B1875 arcs, so in J2000 they are *not* axis-aligned:
    /// precession has rotated them by about two degrees. An edge of constant
    /// B1875 declination therefore drifts in J2000 declination along its
    /// length, and the drift is the evidence that the frame conversion is
    /// actually being applied — draw the boundaries without it and they come
    /// out as a clean staircase in the wrong place.
    ///
    /// How much drift depends on where the edge lies relative to the
    /// precession axis, so this checks the distribution rather than one edge:
    /// some parallel must drift by a quarter of a degree, and the typical one
    /// by a few arcminutes.
    func testTheBoundariesAreNotAxisAlignedInJ2000() throws {
        let boundaries = try XCTUnwrap(Self.boundaries, "boundary table unavailable in this bundle")
        let parallels = boundaries.edges.filter { !$0.isMeridian }
        XCTAssertGreaterThan(parallels.count, 100)

        var drifts: [Double] = []
        for edge in parallels {
            let start = Precession.equatorial(fromVector: boundaries.j2000Direction(
                b1875RightAscension: edge.rightAscension1, declination: edge.declination1
            ))
            let end = Precession.equatorial(fromVector: boundaries.j2000Direction(
                b1875RightAscension: edge.rightAscension2, declination: edge.declination2
            ))
            drifts.append(abs(start.declinationDegrees - end.declinationDegrees))
        }
        let worst = drifts.max() ?? 0
        let mean = drifts.reduce(0, +) / Double(drifts.count)
        XCTAssertGreaterThan(worst, 0.25, "no parallel drifts in J2000 — is the B1875 rotation applied?")
        XCTAssertGreaterThan(mean, 0.01)
        // ...and this is precession, not a bug: nothing moves by degrees.
        XCTAssertLessThan(worst, 3.0)
    }
}
