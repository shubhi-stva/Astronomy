//
//  TimeMachineTests.swift
//  AstronomyTests
//
//  The accuracy and behaviour tests for the Time Machine and the two sky
//  changes that went in with it: precession of the equinoxes, the night-side
//  sub-horizon sky, the satellite element-age guard, and persistent bright-star
//  labels.
//
//  Everything here is synchronous on purpose. An `async` XCTest crashes the
//  test host in this project, and so does running a single test in isolation —
//  always run the whole AstronomyTests suite.
//

import CoreGraphics
import XCTest
import simd
@testable import Astronomy

// MARK: - Precession

/// The load-bearing accuracy tests for the time machine. If precession is
/// wrong, every star in the app is in the wrong place, and the further the
/// clock is moved the wronger it gets.
final class PrecessionTests: XCTestCase {

    /// Jean Meeus, "Astronomical Algorithms", 2nd ed., **Example 21.b**.
    ///
    /// theta Persei precessed from J2000.0 to 2028 November 13.19 TD
    /// (JDE 2462088.69). Meeus applies proper motion first and then precesses;
    /// this app has no proper motions, so the *proper-motion-corrected* J2000
    /// place is used as the input, which is exactly the quantity Meeus feeds
    /// into his precession step:
    ///
    ///     alpha = 2h44m12.975s      delta = +49deg13'39.90"
    ///
    /// and his published answer is
    ///
    ///     alpha = 2h46m11.331s      delta = +49deg20'54.54"
    func testMatchesMeeusExample21b() throws {
        let julianDay = 2_462_088.69

        let inputRA = (2.0 + 44.0 / 60.0 + 12.9747 / 3600.0) * 15.0
        let inputDec = 49.0 + 13.0 / 60.0 + 39.896 / 3600.0

        let result = Precession.precess(
            EquatorialCoordinate(rightAscensionDegrees: inputRA, declinationDegrees: inputDec),
            julianDay: julianDay
        )

        let expectedRA = (2.0 + 46.0 / 60.0 + 11.331 / 3600.0) * 15.0
        let expectedDec = 49.0 + 20.0 / 60.0 + 54.54 / 3600.0

        // A tenth of an arcsecond, which is the precision Meeus prints to.
        let tenthArcsecond = 0.1 / 3600.0
        XCTAssertEqual(
            result.declinationDegrees, expectedDec, accuracy: tenthArcsecond,
            "declination disagrees with Meeus 21.b"
        )
        // The RA tolerance is scaled by cos(dec): a tenth of an arcsecond on
        // the sky is a larger angle in RA at declination +49.
        XCTAssertEqual(
            result.rightAscensionDegrees, expectedRA,
            accuracy: tenthArcsecond / cos(Angle.degreesToRadians(expectedDec)),
            "right ascension disagrees with Meeus 21.b"
        )
    }

    /// The published IAU precessional constants for epoch 2000.0 (Meeus
    /// eq. 21.1): m = 3.07496 seconds of RA per year, n = 20.0431 arcseconds
    /// of declination per year.
    ///
    /// At the vernal equinox (0, 0) the general formulae collapse to exactly
    /// those two numbers, which makes this a genuinely independent check on the
    /// polynomial coefficients — it uses a different published quantity from a
    /// different part of the chapter than the worked example above.
    func testReproducesThePublishedAnnualPrecessionConstants() throws {
        // One Julian year after J2000.0.
        let oneYear = JulianDate.j2000 + 365.25

        let result = Precession.precess(
            EquatorialCoordinate(rightAscensionDegrees: 0, declinationDegrees: 0),
            julianDay: oneYear
        )

        let raSeconds = result.rightAscensionDegrees / 15.0 * 3600.0
        XCTAssertEqual(raSeconds, 3.07496, accuracy: 0.0001, "m disagrees with the IAU value")

        let decArcseconds = result.declinationDegrees * 3600.0
        XCTAssertEqual(decArcseconds, 20.0431, accuracy: 0.001, "n disagrees with the IAU value")
    }

    /// At J2000.0 itself the rotation must be the identity, or every position
    /// in the app is silently offset even at the catalogue epoch.
    func testIsIdentityAtJ2000() throws {
        let star = EquatorialCoordinate(rightAscensionDegrees: 101.287, declinationDegrees: -16.716)
        let result = Precession.precess(star, julianDay: JulianDate.j2000)
        XCTAssertEqual(result.rightAscensionDegrees, star.rightAscensionDegrees, accuracy: 1e-9)
        XCTAssertEqual(result.declinationDegrees, star.declinationDegrees, accuracy: 1e-9)
    }

    /// The correction the app was previously missing. The equinox itself has
    /// regressed about 0.36 degrees by 2026; an individual star's displacement
    /// depends on where it sits relative to the pole, and for Sirius it comes
    /// to 0.28 degrees. Either way it is bigger than the Moon's radius, and
    /// enormous compared with a pixel at any field narrower than a few degrees.
    func testTheCorrectionIsAlreadyVisibleToday() throws {
        // 2026-01-01.
        let jd2026 = JulianDate.j2000 + 26.0 * 365.25
        let sirius = EquatorialCoordinate(rightAscensionDegrees: 101.287, declinationDegrees: -16.716)
        let moved = Precession.precess(sirius, julianDay: jd2026)

        let separation = Angle.radiansToDegrees(
            acos(min(1.0, simd_dot(Precession.unitVector(sirius), Precession.unitVector(moved))))
        )
        XCTAssertEqual(separation, 0.28, accuracy: 0.02)
        XCTAssertGreaterThan(separation, 0.25, "bigger than the Moon's radius, and it was being ignored")
    }

    /// The rotation must be a proper rotation — orthonormal, determinant +1 —
    /// or it would stretch the sky rather than turn it.
    func testRotationIsOrthonormal() throws {
        let m = Precession.rotationMatrix(julianDay: JulianDate.j2000 + 50.0 * 36525.0)
        let product = m.transpose * m
        for row in 0..<3 {
            for column in 0..<3 {
                XCTAssertEqual(
                    product[column][row], row == column ? 1.0 : 0.0, accuracy: 1e-12
                )
            }
        }
        XCTAssertEqual(m.determinant, 1.0, accuracy: 1e-12)
    }

    /// Polaris closes on the pole through the 21st century, reaching its
    /// minimum separation of about half a degree around 2100. A well-known
    /// consequence of precession, and a good end-to-end sanity check on the
    /// sign of the rotation: an inverted sign would move it away instead.
    func testPolarisApproachesThePoleThisCentury() throws {
        let polarisJ2000 = EquatorialCoordinate(
            rightAscensionDegrees: 37.9529, declinationDegrees: 89.2641
        )
        let jd2100 = JulianDate.j2000 + 100.0 * 365.25
        let then = Precession.precess(polarisJ2000, julianDay: jd2100)

        XCTAssertGreaterThan(
            then.declinationDegrees, polarisJ2000.declinationDegrees,
            "Polaris must move toward the pole, not away from it"
        )
        // Roughly 89 deg 32' at closest approach.
        XCTAssertEqual(then.declinationDegrees, 89.53, accuracy: 0.1)
    }
}

// MARK: - The sky below the horizon

final class SubHorizonSkyTests: XCTestCase {

    /// The chord geometry: a sightline at depression |a| leaves the Earth a
    /// great-circle distance 2|a| away, so straight down reaches the antipode
    /// and the Sun's altitude there is exactly the negative of the observer's.
    func testStraightDownSeesTheAntipodalSky() throws {
        let effective = SkyBrightness.sightlineSunAltitudeDegrees(
            sunAltitudeDegrees: 40, viewAltitudeDegrees: -90
        )
        XCTAssertEqual(effective, -40, accuracy: 1e-9)
    }

    /// Continuous at the horizon — no step for the eye to catch as an object
    /// sets.
    func testIsContinuousAcrossTheHorizon() throws {
        let sun = 30.0
        let justAbove = SkyBrightness.effectiveSunAltitudeDegrees(
            sunAltitudeDegrees: sun, viewAltitudeDegrees: 0.001
        )
        let justBelow = SkyBrightness.effectiveSunAltitudeDegrees(
            sunAltitudeDegrees: sun, viewAltitudeDegrees: -0.001
        )
        XCTAssertEqual(justAbove, justBelow, accuracy: 0.01)
    }

    /// By day, the sub-horizon sky is genuinely deeper: the daylight is a
    /// foreground the sightline never crosses.
    func testDaytimeSubHorizonSkyIsDeeperThanTheDaylitOne() throws {
        let noon = 55.0
        let above = SkyBrightness.displayLimitingMagnitude(sunAltitudeDegrees: noon)
        let below = SkyBrightness.displayLimitingMagnitude(
            sunAltitudeDegrees: SkyBrightness.effectiveSunAltitudeDegrees(
                sunAltitudeDegrees: noon, viewAltitudeDegrees: -60
            )
        )
        XCTAssertGreaterThan(below, above + 1.0, "the night side should show far more stars")
        XCTAssertEqual(below, SkyBrightness.darkSkyDisplayCeiling, accuracy: 0.2)
    }

    /// At night nothing regresses. The far end of a downward sightline is the
    /// *day* hemisphere, so the model must keep the observer's own dark sky
    /// rather than substituting a brighter one.
    func testNightTimeSubHorizonSkyIsNeverDimmedByTheDayHemisphere() throws {
        let night = -35.0
        for viewAltitude in stride(from: 0.0, through: -90.0, by: -10.0) {
            let effective = SkyBrightness.effectiveSunAltitudeDegrees(
                sunAltitudeDegrees: night, viewAltitudeDegrees: viewAltitude
            )
            XCTAssertLessThanOrEqual(effective, night + 1e-9,
                                     "the night sky got brighter at view altitude \(viewAltitude)")
        }
    }

    /// The property the whole design rests on: the limit below the horizon is
    /// never *lower* than the limit above it, at any Sun altitude.
    func testTheSubHorizonLimitIsNeverWorseThanTheAboveHorizonOne() throws {
        for sun in stride(from: 80.0, through: -80.0, by: -5.0) {
            let above = SkyBrightness.displayLimitingMagnitude(sunAltitudeDegrees: sun)
            for viewAltitude in stride(from: -1.0, through: -90.0, by: -11.0) {
                let below = SkyBrightness.displayLimitingMagnitude(
                    sunAltitudeDegrees: SkyBrightness.effectiveSunAltitudeDegrees(
                        sunAltitudeDegrees: sun, viewAltitudeDegrees: viewAltitude
                    )
                )
                XCTAssertGreaterThanOrEqual(below, above - 1e-9)
            }
        }
    }

    /// End to end through the geometry builder: at noon, a magnitude-7 star
    /// below the horizon is drawn and the same star above it is not. That is
    /// the user-visible change — the dark hemisphere carries far more stars.
    func testDaytimeDrawsFaintStarsOnlyBelowTheHorizon() throws {
        // Magnitude 6.0: comfortably inside the dark-sky limit and comfortably
        // outside the daylight one (5.6).
        let below = FrameFixtures.starCount(
            magnitude: 6.0, atAltitude: -60, sunAltitudeDegrees: 55
        )
        let above = FrameFixtures.starCount(
            magnitude: 6.0, atAltitude: 60, sunAltitudeDegrees: 55
        )
        XCTAssertEqual(below, 1, "the night-side sky should show a magnitude 6 star")
        XCTAssertEqual(above, 0, "a magnitude 6 star cannot survive a noon sky")
    }
}

// MARK: - Satellite element-age guard

final class SatelliteEpochGuardTests: XCTestCase {

    private static let epoch = 2_460_000.5

    private func frame(elementAgeDays: Double) -> SkyFrameData {
        let julianDay = Self.epoch + elementAgeDays
        var frame = SkyFrameData.empty
        frame.observerLocation = GeographicLocation(latitudeDegrees: 37.5, longitudeDegrees: -122.0)
        frame.julianDay = julianDay
        frame.viewportSize = CGSize(width: 1600, height: 1000)
        frame.cameraCenter = HorizontalCoordinate(altitudeDegrees: 90, azimuthDegrees: 0)
        frame.cameraFieldOfViewDegrees = 90
        frame.sunHorizontal = HorizontalCoordinate(altitudeDegrees: -40, azimuthDegrees: 0)

        let observer = TopocentricTransform.observerPositionTEME(
            observer: frame.observerLocation, julianDay: julianDay
        )
        let position = observer + simd_normalize(observer) * 400.0

        frame.satelliteSnapshot = SatelliteSnapshot(
            julianDay: julianDay,
            samples: [
                SatelliteSample(
                    index: 0, catalogNumber: Satellite.issCatalogNumber,
                    regime: .lowEarth, isNotable: true, epochJulianDay: Self.epoch,
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
                epochJulianDay: Self.epoch, isNotable: true
            )
        ]
        return frame
    }

    private func drawnCount(elementAgeDays: Double) -> Int {
        var builder = SkyGeometryBuilder(frameData: frame(elementAgeDays: elementAgeDays))
        builder.run()
        return builder.projectedObjects.filter { $0.object.kind == .satellite }.count
    }

    /// Inside the window the satellite is drawn as usual — including on the
    /// "before the epoch" side, since elements are no more valid early than
    /// they are late.
    func testSatellitesArePresentWithinTheWindow() throws {
        XCTAssertEqual(drawnCount(elementAgeDays: 0), 1)
        XCTAssertEqual(drawnCount(elementAgeDays: 4.0), 1)
        XCTAssertEqual(drawnCount(elementAgeDays: -4.0), 1)
    }

    /// **The single most important accuracy decision in the time machine.**
    /// A month out, SGP4 has no idea where the satellite is along its orbit, so
    /// the app refuses to draw one rather than inventing a confident position.
    func testSatellitesAreSuppressedBeyondTheWindow() throws {
        XCTAssertEqual(drawnCount(elementAgeDays: 6.0), 0)
        XCTAssertEqual(drawnCount(elementAgeDays: 30.0), 0, "one month out must draw nothing")
        XCTAssertEqual(drawnCount(elementAgeDays: 60.0), 0, "two months out must draw nothing")
        XCTAssertEqual(drawnCount(elementAgeDays: -30.0), 0)
    }

    func testTheGuardIsSymmetricAboutTheEpoch() throws {
        let limit = SatelliteAccuracy.maximumElementSetAgeDays
        XCTAssertTrue(SatelliteAccuracy.isReliable(julianDay: 100 + limit, epochJulianDay: 100))
        XCTAssertTrue(SatelliteAccuracy.isReliable(julianDay: 100 - limit, epochJulianDay: 100))
        XCTAssertFalse(SatelliteAccuracy.isReliable(julianDay: 100 + limit + 0.01, epochJulianDay: 100))
        XCTAssertFalse(SatelliteAccuracy.isReliable(julianDay: 100 - limit - 0.01, epochJulianDay: 100))
    }
}

// MARK: - The dark hemisphere's satellites, and the ISS label

final class SubHorizonSatelliteTests: XCTestCase {

    private static let julianDay = 2_460_000.5

    /// Builds a frame with one satellite at the given horizon altitude, with
    /// the camera pointed straight at it so the altitude-band pre-filter and
    /// the projection both accept it.
    private func frame(
        altitude: Double,
        illumination: TopocentricTransform.Illumination,
        catalogNumber: Int = 1,
        notable: Bool = false
    ) -> SkyFrameData {
        var frame = SkyFrameData.empty
        frame.observerLocation = GeographicLocation(latitudeDegrees: 37.5, longitudeDegrees: -122.0)
        frame.julianDay = Self.julianDay
        frame.viewportSize = CGSize(width: 1600, height: 1000)
        frame.cameraCenter = HorizontalCoordinate(altitudeDegrees: altitude, azimuthDegrees: 180)
        frame.cameraFieldOfViewDegrees = 90
        frame.sunHorizontal = HorizontalCoordinate(altitudeDegrees: -40, azimuthDegrees: 0)

        // A satellite 400 km along the requested look direction, so its true
        // projected place matches the altitude the sample advertises.
        let observer = TopocentricTransform.observerPositionTEME(
            observer: frame.observerLocation, julianDay: Self.julianDay
        )
        let up = simd_normalize(observer)
        // A horizontal basis at the observer, then the look direction in it.
        let north = simd_normalize(SIMD3(0.0, 0.0, 1.0) - up * up.z)
        let east = simd_normalize(simd_cross(SIMD3(0.0, 0.0, 1.0), up))
        let altRad = Angle.degreesToRadians(altitude)
        let azRad = Angle.degreesToRadians(180.0)
        let direction = up * sin(altRad)
            + north * (cos(altRad) * cos(azRad))
            + east * (cos(altRad) * sin(azRad))
        let position = observer + simd_normalize(direction) * 400.0

        frame.satelliteSnapshot = SatelliteSnapshot(
            julianDay: Self.julianDay,
            samples: [
                SatelliteSample(
                    index: 0, catalogNumber: catalogNumber, regime: .lowEarth,
                    isNotable: notable, epochJulianDay: Self.julianDay,
                    position: position, velocity: SIMD3(0, 7.5, 0),
                    illumination: illumination, altitudeDegreesAtSnapshot: altitude
                )
            ],
            propagationDuration: 0
        )
        frame.satelliteDescriptors = [
            SatelliteDescriptor(
                catalogNumber: catalogNumber, name: "TEST \(catalogNumber)",
                regime: .lowEarth, internationalDesignator: "00001A",
                epochJulianDay: Self.julianDay, isNotable: notable
            )
        ]
        return frame
    }

    private func drawn(_ frame: SkyFrameData) -> [ProjectedObject] {
        var builder = SkyGeometryBuilder(frameData: frame)
        builder.run()
        return builder.projectedObjects.filter { $0.object.kind == .satellite }
    }

    /// The change the user asked for: everything orbiting the dark hemisphere
    /// is drawn by default, without "Show all", eclipsed or not. Seeing them
    /// through the Earth is the entire point of the see-through view.
    func testSubHorizonSatellitesAreDrawnWithoutShowAll() throws {
        var eclipsed = frame(altitude: -50, illumination: .umbra)
        eclipsed.showAllSatellites = false
        XCTAssertEqual(drawn(eclipsed).count, 1)

        var sunlit = frame(altitude: -50, illumination: .sunlit)
        sunlit.showAllSatellites = false
        XCTAssertEqual(drawn(sunlit).count, 1)
    }

    /// The above-horizon rules are untouched: an eclipsed satellite overhead is
    /// invisible from the ground, so it stays behind "Show all".
    func testAboveHorizonEclipsedSatelliteStillNeedsShowAll() throws {
        var data = frame(altitude: 80, illumination: .umbra)
        data.showAllSatellites = false
        XCTAssertTrue(drawn(data).isEmpty)
    }

    /// The ISS carries its name whenever it is on screen, at full strength,
    /// with no selection and no click — even on a dim eclipsed pass where an
    /// ordinary notable object's label would fade.
    func testISSIsLabelledContinuouslyAtFullStrength() throws {
        let data = frame(
            altitude: 80, illumination: .umbra,
            catalogNumber: Satellite.issCatalogNumber, notable: true
        )
        var builder = SkyGeometryBuilder(frameData: data)
        builder.run()

        let label = builder.labelCandidates.first {
            $0.id == "sat-\(Satellite.issCatalogNumber)"
        }
        XCTAssertNotNil(label, "the ISS was not labelled")
        XCTAssertEqual(label?.style, .satellite)
        XCTAssertEqual(label?.strength ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(label?.priority, .satellite,
                       "the ISS must not outrank a planet")
    }

    /// Another notable object on the same dim pass keeps the old
    /// visibility-scaled strength, so this is genuinely an ISS-only rule.
    func testOtherNotableSatellitesKeepTheirExistingBehaviour() throws {
        let data = frame(
            altitude: 80, illumination: .umbra, catalogNumber: 20580, notable: true
        )
        var builder = SkyGeometryBuilder(frameData: data)
        builder.run()
        let label = builder.labelCandidates.first { $0.id == "sat-20580" }
        XCTAssertNotNil(label)
        XCTAssertLessThan(label?.strength ?? 1.0, 1.0)
    }
}

// MARK: - Persistent bright-star labels

final class BrightStarLabelTests: XCTestCase {

    /// The rule is data-driven — a magnitude threshold plus a proper name in
    /// the catalogue — not a hard-coded list, so it keeps working if the
    /// catalogue is ever replaced.
    func testTheRuleIsMagnitudePlusAProperName() throws {
        XCTAssertTrue(SkyGeometryBuilder.isPersistentlyLabelled(
            Star(id: 1, name: "Vega", ra: 279.23, dec: 38.78, magnitude: 0.03,
                 colorIndex: 0.0, spectralType: nil)
        ))
        // Bright but unnamed: no label without zooming in.
        XCTAssertFalse(SkyGeometryBuilder.isPersistentlyLabelled(
            Star(id: 2, name: nil, ra: 0, dec: 0, magnitude: 0.5,
                 colorIndex: nil, spectralType: nil)
        ))
        // Named but not first magnitude: keeps the old zoom-gated behaviour.
        XCTAssertFalse(SkyGeometryBuilder.isPersistentlyLabelled(
            Star(id: 3, name: "Alcor", ra: 201.3, dec: 54.99, magnitude: 3.99,
                 colorIndex: nil, spectralType: nil)
        ))
    }

    /// The whole bundled catalogue must yield a small, curated-feeling set —
    /// the stars people actually name — rather than hundreds.
    func testTheBundledCatalogueYieldsAHandfulOfFamousStars() throws {
        let stars = try XCTUnwrap(try? loadBundledStars())
        let persistent = stars.filter(SkyGeometryBuilder.isPersistentlyLabelled)

        XCTAssertGreaterThan(persistent.count, 12, "too few stars to be useful")
        XCTAssertLessThan(persistent.count, 40, "this would be a wall of text")

        let names = Set(persistent.map(\.displayName))
        for expected in [
            "Sirius", "Vega", "Betelgeuse", "Rigel", "Arcturus", "Capella",
            "Procyon", "Altair", "Aldebaran", "Antares", "Spica", "Pollux",
            "Deneb", "Regulus",
        ] {
            XCTAssertTrue(names.contains(expected), "\(expected) should be labelled by default")
        }
    }

    /// At a normal wide field only a few of them are on screen at once. The
    /// whole-sky bound is what keeps the view from filling with text: half the
    /// list is below the horizon, and a 90-degree field is a fraction of what
    /// is left.
    func testAWideFieldShowsOnlyAFewOfThemAtOnce() throws {
        let stars = try XCTUnwrap(try? loadBundledStars())
        let persistent = stars.filter(SkyGeometryBuilder.isPersistentlyLabelled)

        var frame = SkyFrameData.empty
        frame.stars = persistent
        frame.starsByID = Dictionary(uniqueKeysWithValues: persistent.map { ($0.id, $0) })
        frame.observerLocation = GeographicLocation(latitudeDegrees: 37.5, longitudeDegrees: -122.0)
        frame.julianDay = 2_460_000.5
        frame.viewportSize = CGSize(width: 1600, height: 1000)
        frame.cameraCenter = HorizontalCoordinate(altitudeDegrees: 45, azimuthDegrees: 180)
        frame.cameraFieldOfViewDegrees = 90
        frame.sunHorizontal = HorizontalCoordinate(altitudeDegrees: -40, azimuthDegrees: 0)

        var builder = SkyGeometryBuilder(frameData: frame)
        builder.run()
        let starLabels = builder.labelCandidates.filter { $0.style == .star && $0.strength > 0.2 }

        XCTAssertGreaterThan(starLabels.count, 0, "a wide field should still name something")
        XCTAssertLessThanOrEqual(starLabels.count, 10, "a wide field should show a handful, not a crowd")
    }

    private func loadBundledStars() throws -> [Star] {
        let bundle = Bundle(for: BrightStarLabelTests.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: "stars", withExtension: "json")
                ?? Bundle.main.url(forResource: "stars", withExtension: "json")
        )
        return try JSONDecoder().decode([Star].self, from: Data(contentsOf: url))
    }
}

// MARK: - Time controller

@MainActor
final class TimeMachineControllerTests: XCTestCase {

    private var calendar: Calendar {
        Calendar.current
    }

    /// "One month from now" has to mean what the calendar means — the same
    /// clock time on the same day of the next month — not 30 fixed days.
    func testSteppingByMonthLandsOnTheRightInstant() throws {
        let controller = TimeController()
        let before = controller.date
        controller.step(.month, by: 1)

        let expected = try XCTUnwrap(calendar.date(byAdding: .month, value: 1, to: before))
        XCTAssertEqual(controller.date.timeIntervalSince(expected), 0, accuracy: 1.0)

        // And two months, which is the user's other stated question.
        controller.step(.month, by: 1)
        let expectedTwo = try XCTUnwrap(calendar.date(byAdding: .month, value: 2, to: before))
        XCTAssertEqual(controller.date.timeIntervalSince(expectedTwo), 0, accuracy: 2.0)
    }

    func testSteppingByYearLandsOnTheRightInstant() throws {
        let controller = TimeController()
        let before = controller.date
        controller.step(.year, by: 1)
        let expected = try XCTUnwrap(calendar.date(byAdding: .year, value: 1, to: before))
        XCTAssertEqual(controller.date.timeIntervalSince(expected), 0, accuracy: 1.0)

        controller.step(.year, by: -1)
        XCTAssertEqual(controller.date.timeIntervalSince(before), 0, accuracy: 2.0)
    }

    func testSteppingBackwardsUndoesSteppingForwards() throws {
        let controller = TimeController()
        let before = controller.date
        controller.step(.hour, by: 5)
        XCTAssertEqual(controller.date.timeIntervalSince(before), 5 * 3600, accuracy: 1.0)
        controller.step(.hour, by: -5)
        XCTAssertEqual(controller.date.timeIntervalSince(before), 0, accuracy: 1.0)
    }

    /// The rate is a multiplier on how fast the offset itself grows, so
    /// simulated time is linear in real time — continuous, never stepped.
    func testPlaybackRateAdvancesTimeContinuously() throws {
        let controller = TimeController()
        controller.setPlaybackRate(.hourPerSecond)
        XCTAssertFalse(controller.isFollowingRealTime, "60x is not real time")

        let first = controller.date
        Thread.sleep(forTimeInterval: 0.05)
        let second = controller.date

        // 0.05 real seconds at 3600x is 180 simulated seconds.
        let advanced = second.timeIntervalSince(first)
        XCTAssertEqual(advanced, 180, accuracy: 60)

        // Continuous, not quantised: three closely spaced reads must all differ.
        var previous = controller.date
        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 0.005)
            let next = controller.date
            XCTAssertGreaterThan(next, previous)
            previous = next
        }
    }

    /// Changing the rate must not teleport the sky: simulated time is
    /// continuous across the change.
    func testChangingTheRateDoesNotJumpSimulatedTime() throws {
        let controller = TimeController()
        controller.setPlaybackRate(.dayPerSecond)
        Thread.sleep(forTimeInterval: 0.05)

        let before = controller.date
        controller.setPlaybackRate(.realTime)
        let after = controller.date
        // Tolerance is generous because the two reads straddle the re-anchor
        // itself: at a day a second, a hundred microseconds of real time is
        // several simulated seconds. What is being ruled out is the *jump* a
        // naive rate change causes — retroactively re-scaling the whole elapsed
        // interval, which at this rate would be hours.
        XCTAssertEqual(after.timeIntervalSince(before), 0, accuracy: 60)
    }

    /// Pausing freezes simulated time while the real clock runs on.
    func testPauseFreezesSimulatedTime() throws {
        let controller = TimeController()
        controller.setPlaying(false)
        let first = controller.date
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(controller.date.timeIntervalSince(first), 0, accuracy: 0.005)
        XCTAssertFalse(controller.isFollowingRealTime)

        controller.setPlaying(true)
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertGreaterThan(controller.date, first)
    }

    /// "Now" restores real time completely — the instant *and* ordinary 1x
    /// playback, because "now" running at a day a second stops being now.
    func testNowRestoresRealTimeFromAnyState() throws {
        let controller = TimeController()
        controller.step(.month, by: 2)
        controller.setPlaybackRate(.dayPerSecond)
        controller.setPlaying(false)
        XCTAssertFalse(controller.isFollowingRealTime)

        controller.resetToNow()
        XCTAssertTrue(controller.isFollowingRealTime)
        XCTAssertEqual(controller.date.timeIntervalSinceNow, 0, accuracy: 0.1)
        XCTAssertEqual(controller.playbackRate, .realTime)
        XCTAssertTrue(controller.isPlaying)
    }

    /// The seam the whole feature rests on: after a jump, time keeps flowing
    /// from the target rather than freezing there.
    func testTimeKeepsFlowingAfterAJumpAtEveryRate() throws {
        for rate in TimeController.PlaybackRate.allCases {
            let controller = TimeController()
            controller.setPlaybackRate(rate)
            controller.step(.month, by: 1)
            let first = controller.julianDay
            Thread.sleep(forTimeInterval: 0.02)
            XCTAssertGreaterThan(controller.julianDay, first, "stalled at \(rate.label)")
        }
    }

    /// The app must still open at the real local instant. This is the
    /// behaviour that must not regress.
    func testAFreshControllerStartsAtRealTime() throws {
        let controller = TimeController()
        XCTAssertTrue(controller.isFollowingRealTime)
        XCTAssertEqual(controller.offsetFromRealTime, 0, accuracy: 0.05)
        XCTAssertEqual(controller.playbackRate, .realTime)
        XCTAssertTrue(controller.isPlaying)
    }

    /// The planetary models are only fitted for 1800-2050, and the UI clamps
    /// rather than drawing a confident sky outside it.
    func testTheEphemerisWindowClamps() throws {
        let farFuture = Date(timeIntervalSince1970: 100_000_000_000)
        XCTAssertEqual(EphemerisService.clamped(farFuture), EphemerisService.validDateRange.upperBound)

        let farPast = Date(timeIntervalSince1970: -100_000_000_000)
        XCTAssertEqual(EphemerisService.clamped(farPast), EphemerisService.validDateRange.lowerBound)

        let now = Date()
        XCTAssertEqual(EphemerisService.clamped(now), now)
    }
}

// MARK: - Shared fixtures

private enum FrameFixtures {

    /// Number of stars the geometry builder draws for a single star of the
    /// given magnitude placed at the given horizon altitude, with the camera
    /// looking straight at it.
    ///
    /// The star's catalogue coordinate is de-precessed first (the inverse of
    /// the rotation the builder applies), so it lands at exactly the requested
    /// alt/az in the frame being drawn.
    static func starCount(
        magnitude: Double, atAltitude altitude: Double, sunAltitudeDegrees sun: Double
    ) -> Int {
        let julianDay = 2_460_000.5
        let observer = GeographicLocation(latitudeDegrees: 37.5, longitudeDegrees: -122.0)
        let target = HorizontalCoordinate(altitudeDegrees: altitude, azimuthDegrees: 180)

        let ofDate = CoordinateTransformService.equatorial(
            from: target, observer: observer, julianDay: julianDay
        )
        let inverse = Precession.rotationMatrix(julianDay: julianDay).transpose
        let j2000 = Precession.equatorial(fromVector: inverse * Precession.unitVector(ofDate))

        let star = Star(
            id: 1, name: nil, ra: j2000.rightAscensionDegrees,
            dec: j2000.declinationDegrees, magnitude: magnitude,
            colorIndex: nil, spectralType: nil
        )

        var frame = SkyFrameData.empty
        frame.stars = [star]
        frame.starsByID = [1: star]
        frame.observerLocation = observer
        frame.julianDay = julianDay
        frame.viewportSize = CGSize(width: 1600, height: 1000)
        frame.cameraCenter = target
        frame.cameraFieldOfViewDegrees = 30
        frame.sunHorizontal = HorizontalCoordinate(altitudeDegrees: sun, azimuthDegrees: 90)

        var builder = SkyGeometryBuilder(frameData: frame)
        builder.run()
        return builder.projectedObjects.filter { $0.object.kind == .star }.count
    }
}
