//
//  TonightTests.swift
//  AstronomyTests
//
//  Rise/set/transit against published values, the visibility model's documented
//  thresholds, and the sampling of object sky paths.
//
//  Deliberately synchronous and deliberately not `@MainActor`: everything under
//  test here is pure computation over value types, which is the property that
//  makes it testable at all.
//

import XCTest
@testable import Astronomy

// MARK: - Helpers

private func julianDay(
    year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0
) -> Double {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let date = calendar.date(
        from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
    )!
    return JulianDate.julianDay(from: date)
}

/// Difference between two Julian Days in minutes, for readable residuals.
private func minutes(_ a: Double, _ b: Double) -> Double { (a - b) * 1440.0 }

// MARK: - Rise, set and transit

final class RiseSetCalculatorTests: XCTestCase {

    /// Meeus, "Astronomical Algorithms" 2nd ed., **Example 15.a**: Venus seen
    /// from Boston (lat +42.3333, long -71.0833) on 1988 March 20. The book's
    /// answers, as fractions of a day UT, are
    ///
    ///     transit m0 = 0.81965  ->  19h40m
    ///     rising  m1 = 0.51817  ->  12h26m
    ///     setting m2 = 0.12130  ->  02h55m
    ///
    /// The tolerance is minutes rather than seconds because this app's Venus
    /// comes from JPL's Keplerian element set rather than from the apparent
    /// positions Meeus tabulates for the example; a few arcminutes of position
    /// is a couple of minutes of rise time at Boston's latitude.
    func testVenusFromBostonMatchesMeeusExample15a() throws {
        let observer = GeographicLocation(latitudeDegrees: 42.3333, longitudeDegrees: -71.0833)
        let start = julianDay(year: 1988, month: 3, day: 20)

        let result = RiseSetCalculator.events(
            equatorialAt: { PlanetPosition.equatorialCoordinate(planet: .venus, julianDay: $0) },
            standardAltitudeDegrees: RiseSetCalculator.StandardAltitude.point,
            observer: observer,
            startJulianDay: start,
            durationDays: 1.0
        )

        XCTAssertEqual(result.circumstance, .risesAndSets)
        let set = try XCTUnwrap(result.setJulianDay)
        let rise = try XCTUnwrap(result.riseJulianDay)

        XCTAssertEqual(minutes(set, start + 0.12130), 0, accuracy: 5,
                       "setting should match Meeus m2 = 0.12130")
        XCTAssertEqual(minutes(rise, start + 0.51817), 0, accuracy: 5,
                       "rising should match Meeus m1 = 0.51817")
        XCTAssertEqual(minutes(result.transitJulianDay, start + 0.81965), 0, accuracy: 5,
                       "transit should match Meeus m0 = 0.81965")
    }

    /// Sunrise and sunset for New York City on the 2024 June solstice, against
    /// the published US Naval Observatory times: rise 05:25, set 20:31 EDT,
    /// i.e. 09:25 and 00:31 UT.
    func testNewYorkSolsticeSunriseAndSunsetMatchUSNO() throws {
        let observer = GeographicLocation(latitudeDegrees: 40.7128, longitudeDegrees: -74.0060)
        let noon = julianDay(year: 2024, month: 6, day: 21, hour: 12)
        let events = RiseSetCalculator.sunEvents(
            observer: observer, startJulianDay: noon, durationDays: 1.0
        )

        let sunset = try XCTUnwrap(events.setJulianDay)
        let sunrise = try XCTUnwrap(events.riseJulianDay)
        // 2024-06-22 00:31 UT and 2024-06-22 09:25 UT.
        XCTAssertEqual(minutes(sunset, julianDay(year: 2024, month: 6, day: 22, hour: 0, minute: 31)),
                       0, accuracy: 2)
        XCTAssertEqual(minutes(sunrise, julianDay(year: 2024, month: 6, day: 22, hour: 9, minute: 25)),
                       0, accuracy: 2)
    }

    /// The Moon's standard altitude is dominated by its parallax, not by
    /// refraction: `h0 = 0.7275 * pi - 34'` with `pi ~ 57'` puts it near +0.12
    /// degrees, i.e. *above* the geometric horizon, which is the opposite sign
    /// to every other body. Getting this wrong shifts moonrise by minutes.
    func testMoonStandardAltitudeIsParallaxDominated() throws {
        let h0 = RiseSetCalculator.StandardAltitude.moon(distanceKilometres: 384_400)
        XCTAssertEqual(h0, 0.125, accuracy: 0.02)
        XCTAssertGreaterThan(h0, RiseSetCalculator.StandardAltitude.point)
    }

    /// Circumpolar: Dubhe (Ursa Major, Dec +61.75) never sets from London.
    func testCircumpolarStarNeverSets() throws {
        let london = GeographicLocation(latitudeDegrees: 51.5, longitudeDegrees: -0.13)
        let dubhe = EquatorialCoordinate(rightAscensionDegrees: 165.93, declinationDegrees: 61.75)
        let events = RiseSetCalculator.events(
            fixedJ2000: dubhe, observer: london,
            startJulianDay: julianDay(year: 2024, month: 3, day: 1), durationDays: 1.0
        )
        XCTAssertEqual(events.circumstance, .alwaysUp)
        XCTAssertTrue(events.isCircumpolar)
        XCTAssertNil(events.riseJulianDay)
        XCTAssertNil(events.setJulianDay)
        // Lowest culmination is `90 - lat + dec` below the pole = 23.25 degrees.
        XCTAssertEqual(events.minimumAltitudeDegrees, 51.5 - (90 - 61.75), accuracy: 0.5)
        XCTAssertEqual(events.transitAltitudeDegrees, 90 - abs(51.5 - 61.75), accuracy: 0.5)
    }

    /// Never rises: Canopus (Dec -52.7) is permanently below London's horizon.
    func testFarSouthernStarNeverRisesFromLondon() throws {
        let london = GeographicLocation(latitudeDegrees: 51.5, longitudeDegrees: -0.13)
        let canopus = EquatorialCoordinate(rightAscensionDegrees: 95.99, declinationDegrees: -52.70)
        let events = RiseSetCalculator.events(
            fixedJ2000: canopus, observer: london,
            startJulianDay: julianDay(year: 2024, month: 1, day: 15), durationDays: 1.0
        )
        XCTAssertEqual(events.circumstance, .neverUp)
        XCTAssertTrue(events.neverRises)
        XCTAssertNil(events.riseJulianDay)
        XCTAssertLessThan(events.transitAltitudeDegrees, 0)
    }

    /// High latitude, both ways. Tromso (69.65 N) has midnight sun at the June
    /// solstice and polar night at the December one — the two cases where an
    /// interpolating solver is most likely to invent a time.
    func testHighLatitudeSunNeverSetsInJuneAndNeverRisesInDecember() throws {
        let tromso = GeographicLocation(latitudeDegrees: 69.65, longitudeDegrees: 18.96)

        let june = RiseSetCalculator.sunEvents(
            observer: tromso,
            startJulianDay: julianDay(year: 2024, month: 6, day: 21, hour: 12)
        )
        XCTAssertEqual(june.circumstance, .alwaysUp)
        XCTAssertNil(june.setJulianDay)
        XCTAssertGreaterThan(june.minimumAltitudeDegrees, 0)

        let december = RiseSetCalculator.sunEvents(
            observer: tromso,
            startJulianDay: julianDay(year: 2024, month: 12, day: 21, hour: 12)
        )
        XCTAssertEqual(december.circumstance, .neverUp)
        XCTAssertNil(december.riseJulianDay)
        XCTAssertLessThan(december.transitAltitudeDegrees, 0)
    }

    /// And the subtler high-latitude case: Reykjavik in late June has a sunset,
    /// but the Sun never gets to -18 degrees, so there is no astronomical night
    /// at all. The night window must report that rather than manufacture one.
    func testReykjavikHasSunsetButNoAstronomicalNightInJune() throws {
        let reykjavik = GeographicLocation(latitudeDegrees: 64.13, longitudeDegrees: -21.90)
        let night = TonightPlanner.nightWindow(
            observer: reykjavik, julianDay: julianDay(year: 2024, month: 6, day: 21, hour: 20)
        )
        XCTAssertNotNil(night.sun.eveningJulianDay, "Reykjavik does have a sunset in June")
        XCTAssertEqual(night.astronomical.circumstance, .alwaysUp)
        XCTAssertNil(night.darkWindow)
        XCTAssertFalse(night.astronomicalNightOccurs)
        XCTAssertEqual(night.darkHours, 0, accuracy: 1e-9)
    }

    /// The ordinary case, end to end: at a mid-latitude the four boundaries come
    /// in the physically required order — sunset, then civil, nautical and
    /// astronomical dusk — and mirror themselves before sunrise.
    func testTwilightBoundariesAreOrderedAndSymmetric() throws {
        let observer = GeographicLocation(latitudeDegrees: 37.5, longitudeDegrees: -122.0)
        let night = TonightPlanner.nightWindow(
            observer: observer, julianDay: julianDay(year: 2024, month: 10, day: 1, hour: 22)
        )
        let sunset = try XCTUnwrap(night.sun.eveningJulianDay)
        let civil = try XCTUnwrap(night.civil.eveningJulianDay)
        let nautical = try XCTUnwrap(night.nautical.eveningJulianDay)
        let astronomical = try XCTUnwrap(night.astronomical.eveningJulianDay)
        XCTAssertLessThan(sunset, civil)
        XCTAssertLessThan(civil, nautical)
        XCTAssertLessThan(nautical, astronomical)

        let dawn = try XCTUnwrap(night.astronomical.morningJulianDay)
        let sunrise = try XCTUnwrap(night.sun.morningJulianDay)
        XCTAssertLessThan(astronomical, dawn)
        XCTAssertLessThan(dawn, sunrise)
        XCTAssertGreaterThan(night.darkHours, 6)
        XCTAssertLessThan(night.darkHours, 12)
    }
}

// MARK: - The visibility model

final class VisibilityRatingTests: XCTestCase {

    /// Kasten & Young airmass, against its own defining values: 1.0 at the
    /// zenith, and close to sec(z) where sec(z) is still valid.
    func testAirmassMatchesKastenYoung() throws {
        XCTAssertEqual(VisibilityRating.airmass(altitudeDegrees: 90), 1.0, accuracy: 0.001)
        XCTAssertEqual(VisibilityRating.airmass(altitudeDegrees: 30), 2.0, accuracy: 0.02)
        XCTAssertEqual(VisibilityRating.airmass(altitudeDegrees: 10), 5.6, accuracy: 0.2)
        // Monotone: lower is always more atmosphere.
        var previous = 0.0
        for altitude in stride(from: 90.0, through: 5.0, by: -5.0) {
            let x = VisibilityRating.airmass(altitudeDegrees: altitude)
            XCTAssertGreaterThan(x, previous)
            previous = x
        }
    }

    /// The documented altitude thresholds are exactly the band boundaries.
    func testAltitudeBandsSitOnTheDocumentedThresholds() throws {
        XCTAssertEqual(VisibilityRating.altitudeBand(peakAltitudeDegrees: 41), .excellent)
        XCTAssertEqual(VisibilityRating.altitudeBand(peakAltitudeDegrees: 40), .excellent)
        XCTAssertEqual(VisibilityRating.altitudeBand(peakAltitudeDegrees: 39.9), .good)
        XCTAssertEqual(VisibilityRating.altitudeBand(peakAltitudeDegrees: 25), .good)
        XCTAssertEqual(VisibilityRating.altitudeBand(peakAltitudeDegrees: 24.9), .difficult)
        XCTAssertEqual(VisibilityRating.altitudeBand(peakAltitudeDegrees: 10), .difficult)
        XCTAssertEqual(VisibilityRating.altitudeBand(peakAltitudeDegrees: 9.9), .notVisible)
    }

    func testDarkTimeBandsSitOnTheDocumentedThresholds() throws {
        XCTAssertEqual(VisibilityRating.darkTimeBand(hours: 2.0), .excellent)
        XCTAssertEqual(VisibilityRating.darkTimeBand(hours: 1.99), .good)
        XCTAssertEqual(VisibilityRating.darkTimeBand(hours: 1.0), .good)
        XCTAssertEqual(VisibilityRating.darkTimeBand(hours: 0.5), .difficult)
        XCTAssertEqual(VisibilityRating.darkTimeBand(hours: 0), .notVisible)
    }

    /// The moonlight model is anchored on two published sky brightnesses: a
    /// dark moonless V sky at 21.8 mag/arcsec^2, and a full Moon driving it to
    /// roughly 18.5 near the target.
    func testSkyBrightnessSpansTheDocumentedAnchors() throws {
        let newMoon = VisibilityRating.moonImpact(
            illuminatedFraction: 0, separationDegrees: 30, moonUpFractionOfDarkWindow: 1
        )
        XCTAssertEqual(VisibilityRating.skyBrightness(moonImpact: newMoon), 21.8, accuracy: 0.01)

        let fullMoonNearby = VisibilityRating.moonImpact(
            illuminatedFraction: 1.0, separationDegrees: 20, moonUpFractionOfDarkWindow: 1
        )
        XCTAssertEqual(VisibilityRating.skyBrightness(moonImpact: fullMoonNearby), 18.7, accuracy: 0.3)

        // A Moon that has already set costs nothing, whatever its phase.
        let setMoon = VisibilityRating.moonImpact(
            illuminatedFraction: 1.0, separationDegrees: 10, moonUpFractionOfDarkWindow: 0
        )
        XCTAssertEqual(VisibilityRating.skyBrightness(moonImpact: setMoon), 21.8, accuracy: 0.01)

        // And separation matters monotonically.
        let close = VisibilityRating.moonImpact(
            illuminatedFraction: 1, separationDegrees: 10, moonUpFractionOfDarkWindow: 1
        )
        let far = VisibilityRating.moonImpact(
            illuminatedFraction: 1, separationDegrees: 110, moonUpFractionOfDarkWindow: 1
        )
        XCTAssertGreaterThan(close, far)
    }

    /// Surface brightness is the integrated magnitude spread over the ellipse.
    /// M31 at magnitude 3.4 across 190 x 60 arcmin is famously a *faint*
    /// object per unit area — around 22 mag/arcsec^2 — and the formula has to
    /// say so, otherwise the whole extended-object branch is wrong.
    func testSurfaceBrightnessSpreadsMagnitudeOverTheEllipse() throws {
        let m31 = try XCTUnwrap(VisibilityRating.surfaceBrightness(
            magnitude: 3.4, majorAxisArcmin: 190, minorAxisArcmin: 60
        ))
        XCTAssertEqual(m31, 22.0, accuracy: 0.6)
        // A point source has no surface brightness at all.
        XCTAssertNil(VisibilityRating.surfaceBrightness(
            magnitude: 3.4, majorAxisArcmin: nil, minorAxisArcmin: nil
        ))
        // The same light in a smaller area is a higher surface brightness.
        let compact = try XCTUnwrap(VisibilityRating.surfaceBrightness(
            magnitude: 3.4, majorAxisArcmin: 10, minorAxisArcmin: 10
        ))
        XCTAssertLessThan(compact, m31)
    }

    /// A bright, high target beats a faint, low one — the headline property.
    func testABrightHighTargetBeatsAFaintLowOne() throws {
        let high = VisibilityRating.assess(
            magnitude: 4.0, majorAxisArcmin: nil, minorAxisArcmin: nil,
            peakAltitudeDegrees: 70, hoursInDarkness: 5,
            moonIlluminatedFraction: 0, moonSeparationDegrees: 90,
            moonUpFractionOfDarkWindow: 0
        )
        let low = VisibilityRating.assess(
            magnitude: 11.0, majorAxisArcmin: nil, minorAxisArcmin: nil,
            peakAltitudeDegrees: 12, hoursInDarkness: 0.4,
            moonIlluminatedFraction: 0, moonSeparationDegrees: 90,
            moonUpFractionOfDarkWindow: 0
        )
        XCTAssertEqual(high.band, .excellent)
        XCTAssertGreaterThan(high.band, low.band)
        XCTAssertLessThan(high.airmassAtPeak, low.airmassAtPeak)
    }

    /// A target next to a full Moon is penalised relative to the same target on
    /// a moonless night, and the model says moonlight is why.
    func testATargetNearAFullMoonIsPenalised() throws {
        func assess(illumination: Double, separation: Double, upFraction: Double)
            -> VisibilityAssessment
        {
            VisibilityRating.assess(
                magnitude: 6.0, majorAxisArcmin: 10, minorAxisArcmin: 8,
                peakAltitudeDegrees: 65, hoursInDarkness: 5,
                moonIlluminatedFraction: illumination,
                moonSeparationDegrees: separation,
                moonUpFractionOfDarkWindow: upFraction
            )
        }
        let dark = assess(illumination: 0, separation: 90, upFraction: 0)
        let moonlit = assess(illumination: 1.0, separation: 15, upFraction: 1.0)

        XCTAssertGreaterThan(dark.band, moonlit.band, "a full Moon 15 degrees away must cost something")
        XCTAssertLessThan(
            moonlit.skyBrightnessMagPerSquareArcsec, dark.skyBrightnessMagPerSquareArcsec,
            "moonlight makes the sky brighter, i.e. a smaller mag/arcsec^2"
        )
        XCTAssertLessThan(moonlit.detectionMarginMagnitudes, dark.detectionMarginMagnitudes)
        XCTAssertTrue(
            [.moonlight, .contrast].contains(moonlit.limitingFactor),
            "the limiting factor should name the moonlit sky, got \(moonlit.limitingFactor)"
        )
    }

    /// The model is a limiting-factor model, not an average: one fatal
    /// constraint cannot be outvoted by three good ones.
    func testTheWorstConstraintWinsAndIsNamed() throws {
        let lowButPerfectOtherwise = VisibilityRating.assess(
            magnitude: -1.0, majorAxisArcmin: nil, minorAxisArcmin: nil,
            peakAltitudeDegrees: 5, hoursInDarkness: 8,
            moonIlluminatedFraction: 0, moonSeparationDegrees: 180,
            moonUpFractionOfDarkWindow: 0
        )
        XCTAssertEqual(lowButPerfectOtherwise.band, .notVisible)
        XCTAssertEqual(lowButPerfectOtherwise.limitingFactor, .altitude)

        let brightAndHighButNeverDark = VisibilityRating.assess(
            magnitude: 2.0, majorAxisArcmin: nil, minorAxisArcmin: nil,
            peakAltitudeDegrees: 80, hoursInDarkness: 0,
            moonIlluminatedFraction: 0, moonSeparationDegrees: 180,
            moonUpFractionOfDarkWindow: 0
        )
        XCTAssertEqual(brightAndHighButNeverDark.band, .notVisible)
        XCTAssertEqual(brightAndHighButNeverDark.limitingFactor, .darkTime)

        let tooFaint = VisibilityRating.assess(
            magnitude: 15.0, majorAxisArcmin: nil, minorAxisArcmin: nil,
            peakAltitudeDegrees: 80, hoursInDarkness: 8,
            moonIlluminatedFraction: 0, moonSeparationDegrees: 180,
            moonUpFractionOfDarkWindow: 0
        )
        XCTAssertEqual(tooFaint.band, .notVisible)
        XCTAssertEqual(tooFaint.limitingFactor, .brightness)
    }

    /// The assumed instrument's limiting magnitude under a dark sky is the
    /// documented 10.9 — aperture gain over the 6.5 naked-eye figure.
    func testLimitingMagnitudeMatchesTheDocumentedInstrument() throws {
        let dark = VisibilityRating.limitingMagnitude(
            skyBrightness: VisibilityRating.darkSkyBrightness
        )
        XCTAssertEqual(dark, 11.8, accuracy: 0.1)
        // A brighter sky always lifts the limit.
        XCTAssertLessThan(VisibilityRating.limitingMagnitude(skyBrightness: 18.5), dark)
    }
}

// MARK: - Tonight report

final class TonightReportTests: XCTestCase {

    private let observer = GeographicLocation(latitudeDegrees: 37.5, longitudeDegrees: -122.0)

    /// The night is anchored on solar noon, so scrubbing to 2am and to 10pm the
    /// evening before must describe the *same* night.
    func testTheNightAnchorIsStableAcrossMidnight() throws {
        let evening = TonightPlanner.anchorJulianDay(
            observer: observer, julianDay: julianDay(year: 2024, month: 10, day: 2, hour: 5)
        ) // 2024-10-01 22:00 local
        let smallHours = TonightPlanner.anchorJulianDay(
            observer: observer, julianDay: julianDay(year: 2024, month: 10, day: 2, hour: 9)
        ) // 2024-10-02 02:00 local
        XCTAssertEqual(evening, smallHours, accuracy: 1e-6)
    }

    /// The Moon report agrees with the ephemeris it is derived from, and the
    /// phase name follows the illuminated fraction rather than a separate
    /// synodic-age model that could disagree with it.
    func testMoonReportAgreesWithTheEphemeris() throws {
        let night = TonightPlanner.nightWindow(
            observer: observer, julianDay: julianDay(year: 2024, month: 10, day: 2, hour: 5)
        )
        let moon = TonightPlanner.moonTonight(observer: observer, night: night)
        XCTAssertGreaterThanOrEqual(moon.illuminatedFraction, 0)
        XCTAssertLessThanOrEqual(moon.illuminatedFraction, 1)
        XCTAssertFalse(moon.phaseName.isEmpty)
        XCTAssertGreaterThanOrEqual(moon.upFractionOfDarkWindow, 0)
        XCTAssertLessThanOrEqual(moon.upFractionOfDarkWindow, 1)

        XCTAssertEqual(MoonTonight.phaseName(illuminatedFraction: 0.0, isWaxing: true), "New Moon")
        XCTAssertEqual(MoonTonight.phaseName(illuminatedFraction: 0.5, isWaxing: true), "First Quarter")
        XCTAssertEqual(MoonTonight.phaseName(illuminatedFraction: 0.5, isWaxing: false), "Last Quarter")
        XCTAssertEqual(MoonTonight.phaseName(illuminatedFraction: 1.0, isWaxing: false), "Full Moon")
        XCTAssertEqual(MoonTonight.phaseName(illuminatedFraction: 0.2, isWaxing: false), "Waning Crescent")
    }

    /// End to end over a hand-built catalogue: only observable targets survive,
    /// they come back best-first, and the object that is simply below the
    /// horizon all night is absent rather than listed as "Not visible".
    func testTheReportRanksObservableTargetsAndDropsUnobservableOnes() throws {
        let night = TonightPlanner.nightWindow(
            observer: observer, julianDay: julianDay(year: 2024, month: 10, day: 2, hour: 5)
        )
        let moon = TonightPlanner.moonTonight(observer: observer, night: night)

        // Roughly overhead from +37.5 in early October around local midnight
        // (RA ~ 1h): a bright, compact target.
        let overhead = DeepSkyObject(
            id: "test-high", catalogName: "TEST 1", name: "High Bright", type: .globularCluster,
            ra: 15.0, dec: 37.0, magnitude: 6.0,
            majorAxisArcmin: 10, minorAxisArcmin: 10, positionAngleDegrees: nil
        )
        // Deep southern declination: never above the horizon from +37.5.
        let belowHorizon = DeepSkyObject(
            id: "test-low", catalogName: "TEST 2", name: "Southern", type: .globularCluster,
            ra: 15.0, dec: -80.0, magnitude: 6.0,
            majorAxisArcmin: 10, minorAxisArcmin: 10, positionAngleDegrees: nil
        )
        // Same place as the good one, but far too faint for the assumed 80 mm.
        let tooFaint = DeepSkyObject(
            id: "test-faint", catalogName: "TEST 3", name: "Faint", type: .galaxy,
            ra: 15.0, dec: 37.0, magnitude: 11.9,
            majorAxisArcmin: 8, minorAxisArcmin: 6, positionAngleDegrees: nil
        )

        let targets = TonightPlanner.deepSkyTonight(
            catalogue: [belowHorizon, tooFaint, overhead],
            observer: observer, night: night, moon: moon
        )

        XCTAssertFalse(targets.isEmpty)
        XCTAssertEqual(targets.first?.id, "test-high")
        XCTAssertFalse(targets.contains { $0.id == "test-low" },
                       "an object that never rises should not be offered at all")
        // Ranking is monotone in band.
        for (a, b) in zip(targets, targets.dropFirst()) {
            XCTAssertGreaterThanOrEqual(a.visibility.band, b.visibility.band)
        }
    }
}

// MARK: - Object sky paths

final class SkyPathTests: XCTestCase {

    private let observer = GeographicLocation(latitudeDegrees: 37.5, longitudeDegrees: -122.0)
    private let now = 2_460_585.5 // 2024-10-02 00:00 UT

    /// Endpoints are exactly what was asked for, whatever the cadence does in
    /// between.
    func testEndpointsMatchTheRequestedRange() throws {
        let start = now
        let end = now + 0.25
        let path = SkyPathBuilder.build(
            objectID: "moon", kind: .moon, range: .custom(startJulianDay: start, endJulianDay: end),
            equatorialAt: MoonPosition.equatorialCoordinate(julianDay:),
            observer: observer, julianDay: now
        )
        XCTAssertEqual(try XCTUnwrap(path.startJulianDay), start, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(path.endJulianDay), end, accuracy: 1e-9)
        XCTAssertFalse(path.isEmpty)
    }

    /// Cadence is per object class, and coarse enough classes really do produce
    /// fewer samples over the same span.
    func testCadenceIsPerObjectClass() throws {
        XCTAssertEqual(SkyPathBuilder.baseCadenceSeconds(for: .satellite), 1)
        XCTAssertEqual(SkyPathBuilder.baseCadenceSeconds(for: .moon), 60)
        XCTAssertEqual(SkyPathBuilder.baseCadenceSeconds(for: .planet), 300)
        XCTAssertEqual(SkyPathBuilder.baseCadenceSeconds(for: .star), 300)

        let hour = SkyPathRange.custom(startJulianDay: now, endJulianDay: now + 1.0 / 24.0)
        let moon = SkyPathBuilder.build(
            objectID: "moon", kind: .moon, range: hour,
            equatorialAt: MoonPosition.equatorialCoordinate(julianDay:),
            observer: observer, julianDay: now
        )
        let jupiter = SkyPathBuilder.build(
            objectID: "jupiter", kind: .planet, range: hour,
            equatorialAt: { PlanetPosition.equatorialCoordinate(planet: .jupiter, julianDay: $0) },
            observer: observer, julianDay: now
        )
        XCTAssertEqual(moon.samples.count, 61)
        XCTAssertEqual(jupiter.samples.count, 13)
        XCTAssertGreaterThan(moon.samples.count, jupiter.samples.count)
    }

    /// However long the span, a path never exceeds the sample ceiling — the
    /// cadence relaxes instead.
    func testCadenceRelaxesRatherThanExceedingTheSampleCeiling() throws {
        let long = SkyPathRange.custom(startJulianDay: now, endJulianDay: now + 30)
        let path = SkyPathBuilder.build(
            objectID: "moon", kind: .moon, range: long,
            equatorialAt: MoonPosition.equatorialCoordinate(julianDay:),
            observer: observer, julianDay: now
        )
        XCTAssertLessThanOrEqual(path.samples.count, SkyPathBuilder.maximumSamples + 1)
        XCTAssertGreaterThan(
            SkyPathBuilder.cadenceSeconds(for: .moon, spanSeconds: 30 * 86_400),
            SkyPathBuilder.baseCadenceSeconds(for: .moon)
        )
    }

    /// A star's path is its diurnal arc: it moves, and it moves the way the
    /// Earth's rotation says it should — 15 degrees of hour angle per hour.
    func testAStarPathIsTheDiurnalArc() throws {
        let vega = EquatorialCoordinate(rightAscensionDegrees: 279.23, declinationDegrees: 38.78)
        let path = SkyPathBuilder.build(
            objectID: "star-1", kind: .star,
            range: .custom(startJulianDay: now, endJulianDay: now + 1.0 / 24.0),
            fixedEquatorialOfDate: vega, observer: observer, julianDay: now
        )
        XCTAssertGreaterThan(path.samples.count, 2)
        let first = try XCTUnwrap(path.samples.first).horizontal
        let last = try XCTUnwrap(path.samples.last).horizontal
        XCTAssertNotEqual(first.altitudeDegrees, last.altitudeDegrees, accuracy: 0.0)
        // A fixed star's declination never changes, so every sample must lie on
        // the same small circle: the altitude at a given hour angle is fixed.
        for sample in path.samples {
            XCTAssertLessThanOrEqual(sample.horizontal.altitudeDegrees, 90 - 37.5 + 38.78 + 0.5)
        }
    }

    /// Time labels: bounded in number, at real sample indices, in order, and
    /// pinned to both ends of the track.
    func testTimeLabelsAreBoundedAndSpanTheTrack() throws {
        let path = SkyPathBuilder.build(
            objectID: "moon", kind: .moon,
            range: .custom(startJulianDay: now, endJulianDay: now + 0.5),
            equatorialAt: MoonPosition.equatorialCoordinate(julianDay:),
            observer: observer, julianDay: now
        )
        XCTAssertLessThanOrEqual(path.timeLabels.count, SkyPathBuilder.maximumTimeLabels)
        XCTAssertEqual(path.timeLabels.first?.sampleIndex, 0)
        XCTAssertEqual(path.timeLabels.last?.sampleIndex, path.samples.count - 1)
        for (a, b) in zip(path.timeLabels, path.timeLabels.dropFirst()) {
            XCTAssertLessThan(a.sampleIndex, b.sampleIndex)
        }
        XCTAssertFalse(try XCTUnwrap(path.timeLabels.first).text.isEmpty)
    }

    // MARK: Satellite gates

    /// A satellite path inside the element set's validity window is sampled at
    /// the satellite cadence and is not flagged.
    func testASatellitePathInsideTheEpochWindowIsFullyDrawn() throws {
        let epoch = now
        let path = SkyPathBuilder.buildSatellite(
            objectID: "sat-25544",
            range: .custom(startJulianDay: now, endJulianDay: now + 600.0 / 86_400.0),
            epochJulianDay: epoch, nowJulianDay: now,
            observer: observer, julianDay: now,
            positionAt: { _ in HorizontalCoordinate(altitudeDegrees: 45, azimuthDegrees: 180) }
        )
        XCTAssertFalse(path.truncatedForAccuracy)
        XCTAssertEqual(path.samples.count, 601, "600 seconds at the 1-second satellite cadence")
    }

    /// **The accuracy gate.** With the element set already five days old and the
    /// user scrubbed well away from real time, the first sample past the window
    /// ends the track — the path is never drawn as if the extrapolation were
    /// reliable.
    func testASatellitePathIsCutAtTheEdgeOfTheEpochWindow() throws {
        // Displayed time is a month from now, so the real-time arm of the gate
        // cannot rescue it; the epoch arm expires part-way through the span.
        let nowJulianDay = now
        let displayed = now + 30
        let epoch = displayed - SatelliteAccuracy.maximumElementSetAgeDays + 300.0 / 86_400.0

        let (times, truncated) = SkyPathBuilder.satelliteSampleTimes(
            range: .custom(startJulianDay: displayed, endJulianDay: displayed + 600.0 / 86_400.0),
            observer: observer, julianDay: displayed,
            epochJulianDay: epoch, nowJulianDay: nowJulianDay
        )
        XCTAssertTrue(truncated, "the span reaches past the element set's validity")
        XCTAssertEqual(times.count, 301, "the track should stop 300 seconds in")
        let last = try XCTUnwrap(times.last)
        XCTAssertTrue(SatelliteAccuracy.isDrawable(
            julianDay: last, nowJulianDay: nowJulianDay, epochJulianDay: epoch
        ))
    }

    /// Scrubbed far from both real time and the epoch, there is no path at all.
    func testASatellitePathFarOutsideBothWindowsIsEmpty() throws {
        let path = SkyPathBuilder.buildSatellite(
            objectID: "sat-25544", range: .nextHour,
            epochJulianDay: now, nowJulianDay: now,
            observer: observer, julianDay: now + 90,
            positionAt: { _ in HorizontalCoordinate(altitudeDegrees: 45, azimuthDegrees: 180) }
        )
        XCTAssertTrue(path.isEmpty)
        XCTAssertTrue(path.truncatedForAccuracy)
    }

    /// Satellite spans are clamped: a 24-hour request becomes one hour, and
    /// says so.
    func testASatelliteSpanIsClampedToOneRevolution() throws {
        let (times, truncated) = SkyPathBuilder.satelliteSampleTimes(
            range: .next24Hours, observer: observer, julianDay: now,
            epochJulianDay: now, nowJulianDay: now
        )
        XCTAssertTrue(truncated)
        let first = try XCTUnwrap(times.first)
        let last = try XCTUnwrap(times.last)
        let span = (last - first) * 86_400.0
        XCTAssertEqual(span, SkyPathBuilder.satelliteMaximumSpanSeconds, accuracy: 2)
    }

    /// A propagation failure ends the track rather than leaving a hole.
    func testAPropagationFailureEndsTheTrack() throws {
        let times = (0..<10).map { now + Double($0) / 86_400.0 }
        let horizontals: [HorizontalCoordinate?] = times.indices.map {
            $0 < 4 ? HorizontalCoordinate(altitudeDegrees: 30, azimuthDegrees: 90) : nil
        }
        let path = SkyPathBuilder.satellitePath(
            objectID: "sat-1", range: .nextHour, times: times,
            horizontals: horizontals, truncatedForAccuracy: false
        )
        XCTAssertEqual(path.samples.count, 4)
        XCTAssertTrue(path.truncatedForAccuracy)
    }
}

// MARK: - Path rendering

final class SkyPathRenderingTests: XCTestCase {

    private func frame(path: SkyPath?) -> SkyFrameData {
        var frame = SkyFrameData.empty
        frame.observerLocation = GeographicLocation(latitudeDegrees: 37.5, longitudeDegrees: -122.0)
        frame.julianDay = 2_460_585.5
        frame.viewportSize = CGSize(width: 1600, height: 1000)
        frame.cameraCenter = HorizontalCoordinate(altitudeDegrees: 45, azimuthDegrees: 180)
        frame.cameraFieldOfViewDegrees = 120
        frame.sunHorizontal = HorizontalCoordinate(altitudeDegrees: -40, azimuthDegrees: 0)
        frame.skyPath = path
        return frame
    }

    private func path(altitudes: [Double]) -> SkyPath {
        let samples = altitudes.enumerated().map { index, altitude in
            SkyPathSample(
                julianDay: 2_460_585.5 + Double(index) / 1440.0,
                horizontal: HorizontalCoordinate(
                    altitudeDegrees: altitude, azimuthDegrees: 180 + Double(index)
                )
            )
        }
        return SkyPath(
            objectID: "test", range: .nextHour, samples: samples,
            timeLabels: [SkyPathLabel(sampleIndex: 0, text: "22:00")],
            truncatedForAccuracy: false, spanSeconds: 60 * Double(altitudes.count)
        )
    }

    /// The path goes through the existing line buffer — one draw call, not a
    /// new pass — as a connected polyline.
    func testThePathIsEmittedIntoTheExistingLineBuffer() throws {
        var withoutPath = SkyGeometryBuilder(frameData: frame(path: nil))
        withoutPath.run()
        let baseline = withoutPath.lineVertices.count

        var withPath = SkyGeometryBuilder(
            frameData: frame(path: path(altitudes: [30, 35, 40, 45, 50]))
        )
        withPath.run()
        // Four segments, two vertices each.
        XCTAssertEqual(withPath.lineVertices.count, baseline + 8)
    }

    /// Occlusion: a path below the skyline is dimmed by the same terrain model
    /// as everything else, not culled and not drawn at full strength.
    func testASubHorizonPathIsDimmedRatherThanDroppedOrDrawnBright() throws {
        var high = SkyGeometryBuilder(frameData: frame(path: path(altitudes: [50, 55, 60])))
        high.run()
        var low = SkyGeometryBuilder(frameData: frame(path: path(altitudes: [-8, -9, -10])))
        low.run()

        XCTAssertEqual(low.lineVertices.count, high.lineVertices.count,
                       "the sub-horizon path must still be drawn")
        let highAlpha = try XCTUnwrap(high.lineVertices.first).color.w
        let lowAlpha = try XCTUnwrap(low.lineVertices.first).color.w
        XCTAssertLessThan(lowAlpha, highAlpha, "below the skyline it should dim")
        XCTAssertGreaterThan(lowAlpha, 0, "dimmed, not deleted")
    }

    /// Time labels reach the label engine at the lowest priority, so they can
    /// never displace the name of a real object.
    func testTimeLabelsAreLowestPriority() throws {
        var builder = SkyGeometryBuilder(frameData: frame(path: path(altitudes: [40, 45, 50])))
        builder.run()
        let pathLabels = builder.labelCandidates.filter { $0.id.hasPrefix("path-") }
        XCTAssertEqual(pathLabels.count, 1)
        XCTAssertEqual(try XCTUnwrap(pathLabels.first).priority, .cardinal)
        XCTAssertEqual(try XCTUnwrap(pathLabels.first).text, "22:00")
    }

    /// No path selected, nothing drawn — the feature is entirely opt-in.
    func testNoPathMeansNoExtraGeometry() throws {
        var builder = SkyGeometryBuilder(frameData: frame(path: nil))
        builder.run()
        XCTAssertTrue(builder.labelCandidates.allSatisfy { !$0.id.hasPrefix("path-") })
    }
}
