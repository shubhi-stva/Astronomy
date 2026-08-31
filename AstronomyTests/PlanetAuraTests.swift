//
//  PlanetAuraTests.swift
//  AstronomyTests
//
//  "Venus is not glowing."
//
//  The investigation, because the conclusion is not obvious from the code.
//  Venus was up: from Fremont (37.5N, 122.0W) on 2026-08-30 it sits 44.9
//  degrees east of the Sun, 24 degrees above the horizon at sunset and 3
//  degrees up at the end of nautical twilight — an evening star, well placed,
//  the most prominent thing in the sky. It was not lost in the Sun's glare and
//  it was not below the horizon. And its aura alpha was already pinned to the
//  ceiling, which is why reading `StarAppearance.aura` suggested there was
//  nothing wrong.
//
//  The defect was in the halo's *size*. It was derived only from the drawn
//  disk, and at a wide field a planet's disk is pinned to a floor of at most
//  eleven points, so Venus got a forty-point halo. Sirius — eight magnitudes
//  fainter, and drawn by a completely separate model in `glowSize` — got
//  fifty-eight. The brightest object in the night sky after the Moon was
//  rendering a smaller glow than a first-magnitude star, and next to that
//  comparison it read as a flat dot rather than as something glowing.
//
//  The tests below pin the fix: the ordering against the stars, the ordering
//  among the planets, that every planet which should glow does, that Uranus
//  and Neptune still do not, and that the halo survives the bright twilight
//  sky in which Venus is most prominent.
//

import XCTest
@testable import Astronomy

final class PlanetAuraStrengthTests: XCTestCase {

    /// Apparent magnitudes as `EphemerisService` reports them.
    private static let magnitudes: [(id: String, magnitude: Double)] = [
        ("mercury", -0.4),
        ("venus", -4.2),
        ("mars", -0.5),
        ("jupiter", -2.2),
        ("saturn", 0.5),
        ("uranus", 5.7),
        ("neptune", 7.8),
    ]

    /// The aura a body actually gets on screen: the same magnitude the
    /// ephemeris reports, at the same drawn size the renderer would pick for a
    /// typical 90-degree field on a 1600-point viewport.
    private func onScreenAura(id: String, magnitude: Double) -> StarAppearance.Aura? {
        let size = StarAppearance.solarSystemPointSize(
            objectID: id,
            kind: .planet,
            magnitude: magnitude,
            // Roughly Venus's distance at this elongation; the exact value
            // barely matters, because at a 90-degree field every planet's true
            // disk is far under the floor and the floor is what is drawn.
            distanceKilometres: 1.0e8,
            fieldOfViewDegrees: 90,
            viewportWidth: 1600
        )
        return StarAppearance.aura(
            kind: .planet,
            magnitude: magnitude,
            tint: StarAppearance.planetColor(id: id),
            pointSize: size
        )
    }

    private func aura(_ id: String) -> StarAppearance.Aura? {
        guard let entry = Self.magnitudes.first(where: { $0.id == id }) else { return nil }
        return onScreenAura(id: entry.id, magnitude: entry.magnitude)
    }

    // MARK: - The reported bug

    /// The regression test for the complaint, stated the way the user stated
    /// it: Venus must visibly glow.
    func testVenusGlowsAtItsRealMagnitudeAndARealDrawnSize() throws {
        let venus = try XCTUnwrap(aura("venus"), "Venus has no aura at all")
        XCTAssertGreaterThan(venus.alpha, 0.25, "Venus's halo is too faint to read as a glow")
        XCTAssertGreaterThan(
            venus.size, 50,
            "Venus's halo is too small to read as a glow: it is a ring around a dot, not a bloom"
        )
    }

    /// The comparison that identified the defect. Venus is about eight
    /// magnitudes brighter than Sirius; it must not be given a *smaller* halo
    /// than Sirius by a separate model that never knew about it.
    func testVenusOutGlowsTheBrightestStar() throws {
        let venus = try XCTUnwrap(aura("venus"))
        let sirius = StarAppearance.glowSize(forMagnitude: -1.46)
        XCTAssertGreaterThan(
            venus.size, sirius,
            "Venus, eight magnitudes brighter than Sirius, is drawn with a smaller halo than Sirius"
        )
    }

    /// It out-glows Sirius in *size*, not in density. A planet is a steady
    /// point, not a scintillating one, and the restraint is deliberate.
    func testAPlanetIsNeverDenserThanABrightStar() throws {
        let venus = try XCTUnwrap(aura("venus"))
        XCTAssertLessThan(venus.alpha, StarAppearance.glowAlpha(forMagnitude: -1.46))
        XCTAssertLessThanOrEqual(venus.alpha, StarAppearance.planetAuraMaximumAlpha + 1e-6)
    }

    // MARK: - All the planets, as the user asked

    func testEveryNakedEyePlanetGlows() throws {
        for id in ["mercury", "venus", "mars", "jupiter", "saturn"] {
            let aura = try XCTUnwrap(aura(id), "\(id) has no aura")
            XCTAssertGreaterThan(aura.alpha, 0.10, "\(id)'s halo is too faint to see")
            XCTAssertGreaterThan(aura.size, 30, "\(id)'s halo is too small to see")
        }
    }

    func testTheIceGiantsStillDoNotGlow() {
        // Unchanged, and still correct: at magnitude 5.7 and 7.8 these are
        // telescopic objects, and a halo would be a claim about how they look
        // that is simply false.
        XCTAssertNil(aura("uranus"))
        XCTAssertNil(aura("neptune"))
    }

    func testTheHierarchyRunsVenusJupiterMarsSaturn() throws {
        let venus = try XCTUnwrap(aura("venus"))
        let jupiter = try XCTUnwrap(aura("jupiter"))
        let mars = try XCTUnwrap(aura("mars"))
        let saturn = try XCTUnwrap(aura("saturn"))

        XCTAssertGreaterThan(venus.alpha, jupiter.alpha)
        XCTAssertGreaterThan(jupiter.alpha, mars.alpha)
        XCTAssertGreaterThan(mars.alpha, saturn.alpha)

        // And the same ordering in size, which is the half that was broken.
        XCTAssertGreaterThan(venus.size, jupiter.size)
        XCTAssertGreaterThan(jupiter.size, mars.size)
        XCTAssertGreaterThan(mars.size, saturn.size)
    }

    /// Nothing pops. A planet brightening toward opposition must cross the
    /// threshold with a halo of zero size and zero alpha, not with a visible
    /// one appearing from nowhere.
    func testTheHaloGrowsContinuouslyFromNothingAtTheThreshold() {
        let threshold = StarAppearance.auraMagnitudeThreshold
        XCTAssertNil(onScreenAura(id: "mars", magnitude: threshold))

        var previousAlpha: Float = 0
        var previousSize: Float = 0
        // Walk from just inside the threshold up to Venus's brightness.
        for step in 1...80 {
            let magnitude = threshold - Double(step) * 0.1
            guard let aura = onScreenAura(id: "mars", magnitude: magnitude) else { continue }
            XCTAssertGreaterThanOrEqual(aura.alpha, previousAlpha - 1e-6)
            XCTAssertGreaterThanOrEqual(aura.size, previousSize - 1e-3)
            // No step may jump by a visible amount.
            if previousAlpha > 0 {
                XCTAssertLessThan(aura.alpha - previousAlpha, 0.02)
                XCTAssertLessThan(aura.size - previousSize, 2.0)
            }
            previousAlpha = aura.alpha
            previousSize = aura.size
        }
        XCTAssertGreaterThan(previousAlpha, 0.30)
    }

    /// The brightness term must not survive into the zoomed-in regime and
    /// stop the disk-proportional term taking over. Zoom far enough in and the
    /// halo is still bounded relative to the disk.
    func testTheBrightnessTermDoesNotSurviveIntoTheZoomedInRegime() {
        let wide = StarAppearance.aura(
            kind: .planet, magnitude: -4.2,
            tint: StarAppearance.planetColor(id: "venus"), pointSize: 11
        )!
        let zoomed = StarAppearance.aura(
            kind: .planet, magnitude: -4.2,
            tint: StarAppearance.planetColor(id: "venus"), pointSize: 180
        )!
        XCTAssertGreaterThan(wide.size / 11, zoomed.size / 180)
        XCTAssertLessThanOrEqual(zoomed.size, 200)
    }
}

// MARK: - Surviving a bright sky

final class PlanetAuraTwilightTests: XCTestCase {

    private func venusAura() -> StarAppearance.Aura {
        StarAppearance.aura(
            kind: .planet, magnitude: -4.2,
            tint: StarAppearance.planetColor(id: "venus"), pointSize: 12.4
        )!
    }

    /// The other half of the complaint, and a real defect even though each
    /// individual multiplier was defensible. Venus's moment is dusk. A halo
    /// that fades out exactly then is a halo that is missing whenever anyone
    /// looks for it.
    func testVenusStillGlowsThroughEveryStageOfTwilight() {
        let intrinsic = venusAura().alpha
        // Civil dusk through astronomical night, plus the Sun still up, which
        // is when Venus is a genuine daylight object.
        for sunAltitude in [10.0, 0.0, -3.0, -6.0, -12.0, -18.0] {
            let bodyVisibility = SkyBrightness.starContrast(sunAltitudeDegrees: sunAltitude)
            let auraVisibility = StarAppearance.planetAuraVisibility(bodyVisibility: bodyVisibility)
            let drawn = intrinsic * Float(auraVisibility)
            XCTAssertGreaterThan(
                drawn, 0.25,
                "Venus's halo is washed out at sun altitude \(sunAltitude), which is exactly when it is most prominent"
            )
        }
    }

    /// The halo fades more slowly than the disk, but from the same endpoints.
    func testTheHaloFadesMoreSlowlyThanTheDiskButFromTheSamePlaces() {
        // Exactly 1 at full visibility: the approved night-time look is
        // untouched, byte for byte.
        XCTAssertEqual(StarAppearance.planetAuraVisibility(bodyVisibility: 1.0), 1.0, accuracy: 1e-9)
        // Exactly 0 at zero: a planet dimmed away behind the terrain must not
        // leave a halo glowing over the dunes.
        XCTAssertEqual(StarAppearance.planetAuraVisibility(bodyVisibility: 0.0), 0.0, accuracy: 1e-9)

        // Monotonic, and above the disk everywhere in between.
        var previous = 0.0
        for step in 1...100 {
            let v = Double(step) / 100.0
            let aura = StarAppearance.planetAuraVisibility(bodyVisibility: v)
            XCTAssertGreaterThan(aura, previous)
            if v < 1.0 { XCTAssertGreaterThan(aura, v) }
            previous = aura
        }
    }

    func testOutOfRangeVisibilityIsClamped() {
        XCTAssertEqual(StarAppearance.planetAuraVisibility(bodyVisibility: -1), 0.0, accuracy: 1e-9)
        XCTAssertEqual(StarAppearance.planetAuraVisibility(bodyVisibility: 5), 1.0, accuracy: 1e-9)
    }

    /// A planet fully dimmed by the terrain takes its halo with it.
    func testAPlanetBehindTheTerrainHasNoHalo() {
        XCTAssertEqual(
            venusAura().alpha * Float(StarAppearance.planetAuraVisibility(bodyVisibility: 0)),
            0.0, accuracy: 1e-9
        )
    }
}

// MARK: - Venus was, in fact, up

/// The half of the investigation that could have ended it: if Venus had been
/// below the horizon or lost in the Sun's glare there would have been no bug
/// to fix, and the honest answer would have been to say so. It was not.
final class VenusVisibilityTests: XCTestCase {

    private static let fremont = GeographicLocation(latitudeDegrees: 37.5, longitudeDegrees: -122.0)

    private func julianDay(hourUTC: Int) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 30, hour: hourUTC)
        )!
        return JulianDate.julianDay(from: date)
    }

    private func horizontal(_ id: String, hourUTC: Int) throws -> HorizontalCoordinate {
        let jd = julianDay(hourUTC: hourUTC)
        let object = try XCTUnwrap(
            EphemerisService.solarSystemObjects(julianDay: jd).first { $0.id == id }
        )
        return CoordinateTransformService.horizontal(
            from: object.equatorial, observer: Self.fremont, julianDay: jd
        )
    }

    /// 02:00 UTC is 19:00 PDT — around sunset at Fremont in late August.
    func testVenusIsWellAboveTheHorizonAtSunset() throws {
        let sun = try horizontal("sun", hourUTC: 2)
        let venus = try horizontal("venus", hourUTC: 2)
        XCTAssertLessThan(sun.altitudeDegrees, 15, "this should be near sunset")
        XCTAssertGreaterThan(
            venus.altitudeDegrees, 15,
            "Venus was reported missing; if it were below the horizon there would be no bug"
        )
    }

    /// And it is still up an hour into astronomical twilight, so it is a
    /// genuine evening object rather than something that sets with the Sun.
    func testVenusIsStillUpAfterTheSunHasProperlySet() throws {
        let sun = try horizontal("sun", hourUTC: 4)
        let venus = try horizontal("venus", hourUTC: 4)
        XCTAssertLessThan(sun.altitudeDegrees, -10)
        XCTAssertGreaterThan(venus.altitudeDegrees, 0)
    }

    /// Nor is it lost in the Sun's glare: 45 degrees of elongation is close to
    /// the maximum Venus ever reaches.
    func testVenusIsFarFromTheSun() throws {
        let jd = julianDay(hourUTC: 12)
        let objects = EphemerisService.solarSystemObjects(julianDay: jd)
        let sun = try XCTUnwrap(objects.first { $0.id == "sun" }).equatorial
        let venus = try XCTUnwrap(objects.first { $0.id == "venus" }).equatorial

        let radians = Double.pi / 180
        let d1 = sun.declinationDegrees * radians
        let d2 = venus.declinationDegrees * radians
        let deltaRA = (sun.rightAscensionDegrees - venus.rightAscensionDegrees) * radians
        let cosine = sin(d1) * sin(d2) + cos(d1) * cos(d2) * cos(deltaRA)
        let elongation = acos(max(-1, min(1, cosine))) / radians

        XCTAssertGreaterThan(
            elongation, 30,
            "Venus is not lost in twilight next to the Sun — it is a well-separated evening star"
        )
    }
}
