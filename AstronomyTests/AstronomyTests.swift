//
//  AstronomyTests.swift
//  AstronomyTests
//
//  Unit tests for the pure calculation layer: Julian Date conversion,
//  RA/Dec -> Alt/Az transform, and a Sun-position sanity check against a
//  published reference value.
//

import CoreGraphics
import ImageIO
import XCTest
import simd
@testable import Astronomy

final class JulianDateTests: XCTestCase {

    func testJ2000Epoch() throws {
        // 2000 January 1, 12:00 UTC is JD 2451545.0 exactly (Meeus, Example 7.a).
        var components = DateComponents()
        components.year = 2000
        components.month = 1
        components.day = 1
        components.hour = 12
        components.minute = 0
        components.second = 0

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: components)!

        let jd = JulianDate.julianDay(from: date)
        XCTAssertEqual(jd, 2_451_545.0, accuracy: 0.0001)
    }

    func testKnownHistoricalDate() throws {
        // Meeus Example 7.a: 1957 October 4.81 UT -> JD 2436116.31
        var components = DateComponents()
        components.year = 1957
        components.month = 10
        components.day = 4
        components.hour = 19
        components.minute = 26
        components.second = 24 // 0.81 * 24h = 19h26m24s

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: components)!

        let jd = JulianDate.julianDay(from: date)
        XCTAssertEqual(jd, 2_436_116.31, accuracy: 0.01)
    }

    func testJulianCenturiesAtJ2000() throws {
        XCTAssertEqual(JulianDate.julianCenturies(fromJulianDay: JulianDate.j2000), 0.0, accuracy: 1e-10)
    }
}

final class CoordinateTransformTests: XCTestCase {

    func testZenithStarHasNinetyDegreeAltitude() throws {
        // An object whose RA equals the local sidereal time and whose Dec
        // equals the observer's latitude is exactly at the zenith.
        let jd = JulianDate.julianDay(from: Date())
        let observer = GeographicLocation(latitudeDegrees: 40.0, longitudeDegrees: -74.0)
        let lst = CoordinateTransformService.localSiderealTimeDegrees(julianDay: jd, longitudeDegrees: observer.longitudeDegrees)

        let equatorial = EquatorialCoordinate(rightAscensionDegrees: lst, declinationDegrees: observer.latitudeDegrees)
        let horizontal = CoordinateTransformService.horizontal(from: equatorial, observer: observer, julianDay: jd)

        XCTAssertEqual(horizontal.altitudeDegrees, 90.0, accuracy: 0.01)
    }

    func testNorthCelestialPoleAltitudeEqualsLatitude() throws {
        // The north celestial pole (Dec = +90) appears at an altitude equal
        // to the observer's latitude, at any azimuth/RA/time, for northern
        // observers.
        let jd = JulianDate.julianDay(from: Date())
        let observer = GeographicLocation(latitudeDegrees: 51.5, longitudeDegrees: -0.13) // London
        let equatorial = EquatorialCoordinate(rightAscensionDegrees: 123.4, declinationDegrees: 90.0)
        let horizontal = CoordinateTransformService.horizontal(from: equatorial, observer: observer, julianDay: jd)

        XCTAssertEqual(horizontal.altitudeDegrees, observer.latitudeDegrees, accuracy: 0.01)
        XCTAssertEqual(horizontal.azimuthDegrees, 0.0, accuracy: 0.5)
    }

    func testGreenwichMeanSiderealTimeAtJ2000() throws {
        // Meeus Example 12.a: GMST at 2000-01-01 00:00 UT ~ 6h39m52.2s = 99.9678 deg (approx, low-precision formula).
        let jd = JulianDate.j2000 - 0.5 // 2000-01-01 00:00 UT
        let gmst = CoordinateTransformService.greenwichMeanSiderealTimeDegrees(julianDay: jd)
        // Allow a modest tolerance since we use the simplified (non-apparent) formula.
        XCTAssertEqual(gmst, 99.97, accuracy: 0.2)
    }
}

final class SunPositionTests: XCTestCase {

    func testSunPositionOnKnownDate() throws {
        // Meeus Example 25.a: 1992 October 13.0 TD.
        // Reference apparent RA ~ 198.378deg (13h13.6m), Dec ~ -7.78deg (Meeus final apparent values).
        var components = DateComponents()
        components.year = 1992
        components.month = 10
        components.day = 13
        components.hour = 0
        components.minute = 0
        components.second = 0

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: components)!
        let jd = JulianDate.julianDay(from: date)

        let sun = SunPosition.equatorialCoordinate(julianDay: jd)

        // Reasonable tolerance for a low-precision method vs. Meeus's fuller worked example.
        XCTAssertEqual(sun.rightAscensionDegrees, 198.38, accuracy: 0.5)
        XCTAssertEqual(sun.declinationDegrees, -7.78, accuracy: 0.3)
    }

    func testSunAtMarchEquinoxIsNearCelestialEquator() throws {
        // Near the March equinox (~March 20), the Sun's declination should
        // be close to zero.
        var components = DateComponents()
        components.year = 2024
        components.month = 3
        components.day = 20
        components.hour = 3
        components.minute = 6

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: components)!
        let jd = JulianDate.julianDay(from: date)

        let sun = SunPosition.equatorialCoordinate(julianDay: jd)
        XCTAssertEqual(sun.declinationDegrees, 0.0, accuracy: 0.5)
    }
}

final class ProjectionAspectTests: XCTestCase {

    func testSquareViewportLeavesNDCUnchanged() throws {
        let ndc = SIMD2<Double>(0.4, -0.6)
        let corrected = CoordinateTransformService.aspectCorrected(ndc, viewportSize: CGSize(width: 800, height: 800))
        XCTAssertEqual(corrected.x, ndc.x, accuracy: 1e-9)
        XCTAssertEqual(corrected.y, ndc.y, accuracy: 1e-9)
    }

    func testLandscapeViewportScalesYNotX() throws {
        // 2:1 landscape window: X (horizontal FOV) must pass through
        // unchanged, Y (vertical) scales by width/height = 2.
        let ndc = SIMD2<Double>(0.5, 0.5)
        let corrected = CoordinateTransformService.aspectCorrected(ndc, viewportSize: CGSize(width: 1600, height: 800))
        XCTAssertEqual(corrected.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(corrected.y, 1.0, accuracy: 1e-9)
    }

    func testPortraitViewportScalesYDown() throws {
        // Tall window: width/height = 0.5, so Y should shrink, not X.
        let ndc = SIMD2<Double>(0.5, 0.8)
        let corrected = CoordinateTransformService.aspectCorrected(ndc, viewportSize: CGSize(width: 800, height: 1600))
        XCTAssertEqual(corrected.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(corrected.y, 0.4, accuracy: 1e-9)
    }

    func testAspectUncorrectedIsInverse() throws {
        let ndc = SIMD2<Double>(0.3, -0.2)
        let size = CGSize(width: 1200, height: 700)
        let roundTripped = CoordinateTransformService.aspectUncorrected(
            CoordinateTransformService.aspectCorrected(ndc, viewportSize: size),
            viewportSize: size
        )
        XCTAssertEqual(roundTripped.x, ndc.x, accuracy: 1e-9)
        XCTAssertEqual(roundTripped.y, ndc.y, accuracy: 1e-9)
    }
}

final class SkyBrightnessTests: XCTestCase {

    func testBrightnessIsMonotonicInSunAltitude() throws {
        // Lower Sun must never give a brighter sky. Sampled finely enough to
        // catch a discontinuity or a non-monotonic anchor segment.
        var previous = SkyBrightness.zenithMagnitudesPerSquareArcsecond(sunAltitudeDegrees: 90)
        var alt = 90.0
        while alt >= -40.0 {
            let value = SkyBrightness.zenithMagnitudesPerSquareArcsecond(sunAltitudeDegrees: alt)
            // Magnitudes run backwards: darker sky = larger number.
            XCTAssertGreaterThanOrEqual(value, previous - 1e-9, "regressed at Sun altitude \(alt)")
            // And no step should be large enough to see as banding.
            XCTAssertLessThan(value - previous, 0.35, "jump at Sun altitude \(alt)")
            previous = value
            alt -= 0.1
        }
    }

    func testDaylightHidesStarsButKeepsVenusAndTheLuminaries() throws {
        // Fremont, mid-afternoon: Sun high in the sky.
        let limit = SkyBrightness.limitingMagnitude(sunAltitudeDegrees: 45)
        XCTAssertLessThan(limit, 2.0, "a magnitude 2 star must not be visible at midday")
        XCTAssertLessThan(limit, 0.0, "nothing star-like should survive full daylight")
        XCTAssertGreaterThan(limit, -4.2, "Venus at mag -4.2 must still be visible")
        XCTAssertGreaterThan(limit, -12.7, "the Moon must still be visible")
        // Sanity: the requested -4...-3 band.
        XCTAssertEqual(limit, -3.7, accuracy: 0.6)
    }

    func testCivilTwilightRevealsOnlyTheBrightestObjects() throws {
        // End of civil twilight (-6 deg): the first stars are appearing.
        let limit = SkyBrightness.limitingMagnitude(sunAltitudeDegrees: -6)
        XCTAssertGreaterThan(limit, 0.0)
        XCTAssertLessThan(limit, 3.0, "the faint field must still be invisible at civil dusk")
    }

    func testAstronomicalNightRestoresTheFullNakedEyeField() throws {
        let limit = SkyBrightness.limitingMagnitude(sunAltitudeDegrees: -18)
        XCTAssertGreaterThanOrEqual(limit, 6.0)
        // And it should not run away past the physical naked-eye limit.
        XCTAssertLessThan(SkyBrightness.limitingMagnitude(sunAltitudeDegrees: -40), 7.0)
    }

    func testEffectiveLimitTakesTheMoreRestrictiveOfSkyAndFieldOfView() throws {
        // Deep night at a wide field: the aesthetic FOV limit (4.6) is
        // stricter than the dark-sky limit (~6.5), so it binds.
        let night = StarAppearance.effectiveLimitingMagnitude(
            fieldOfViewDegrees: 150, sunAltitudeDegrees: -30
        )
        XCTAssertEqual(night, StarAppearance.limitingMagnitude(fieldOfViewDegrees: 150), accuracy: 1e-9)

        // Same narrow field at midday: the sky limit binds instead — but it is
        // the *display* limit (floored), not the physical one, so the daytime
        // sky still shows a field of stars.
        let day = StarAppearance.effectiveLimitingMagnitude(
            fieldOfViewDegrees: 3, sunAltitudeDegrees: 45
        )
        XCTAssertEqual(day, SkyBrightness.displayLimitingMagnitude(sunAltitudeDegrees: 45), accuracy: 1e-9)
        // Sitting on the daylight floor (the display curve reaches it
        // asymptotically, so within a hundredth of a magnitude).
        XCTAssertEqual(day, SkyBrightness.daylightDisplayFloor, accuracy: 0.01)
        XCTAssertGreaterThan(
            day, 4.0,
            "a planetarium must show the sky through daylight, not an empty screen"
        )
    }

    func testDisplayLimitNeverEmptiesTheDaytimeSky() throws {
        // Whatever the Sun is doing, the renderer keeps a usable field.
        for alt in stride(from: 90.0, through: -40.0, by: -5.0) {
            XCTAssertGreaterThanOrEqual(
                SkyBrightness.displayLimitingMagnitude(sunAltitudeDegrees: alt),
                SkyBrightness.daylightDisplayFloor - 1e-9,
                "display limit dipped below the floor at Sun altitude \(alt)"
            )
        }
        // At night the physical limit rises past the floor on its own, so a
        // dark sky still gains the faintest stars rather than being clamped.
        XCTAssertGreaterThan(
            SkyBrightness.displayLimitingMagnitude(sunAltitudeDegrees: -30),
            SkyBrightness.daylightDisplayFloor
        )
    }

    func testStarContrastEasesContinuouslyAndNeverVanishes() throws {
        let day = SkyBrightness.starContrast(sunAltitudeDegrees: 45)
        let dusk = SkyBrightness.starContrast(sunAltitudeDegrees: -6)
        let night = SkyBrightness.starContrast(sunAltitudeDegrees: -20)

        // Monotonic: darker sky -> higher contrast.
        XCTAssertLessThan(day, dusk)
        XCTAssertLessThan(dusk, night)
        // Never fully transparent, and never above full strength.
        XCTAssertGreaterThanOrEqual(day, SkyBrightness.daylightContrastFloor - 1e-9)
        XCTAssertEqual(night, 1.0, accuracy: 0.02)

        // No step changes anywhere across the twilight range.
        var previous = SkyBrightness.starContrast(sunAltitudeDegrees: 60)
        for alt in stride(from: 60.0, through: -30.0, by: -0.5) {
            let value = SkyBrightness.starContrast(sunAltitudeDegrees: alt)
            XCTAssertLessThan(abs(value - previous), 0.02, "contrast stepped at \(alt)")
            previous = value
        }
    }

    func testVisibilityFadeIsMagnitudeDependentNotAUniformDimmer() throws {
        // Just after sunset, a bright planet must be more visible than a
        // mid-brightness star — not merely equally dimmed.
        let sunAltitude = -4.0
        let bright = StarAppearance.visibility(
            magnitude: -2.2, fieldOfViewDegrees: 60, sunAltitudeDegrees: sunAltitude
        )
        // Chosen to straddle the fade band: at this field of view the cutoff
        // is ~6.24 (the FOV limit binds, the twilight display limit is ~6.68)
        // and the fade spans the magnitude below it, so 5.8 is partway through
        // the fade and 6.5 is past the cutoff entirely.
        let middling = StarAppearance.visibility(
            magnitude: 5.8, fieldOfViewDegrees: 60, sunAltitudeDegrees: sunAltitude
        )
        let faint = StarAppearance.visibility(
            magnitude: 6.5, fieldOfViewDegrees: 60, sunAltitudeDegrees: sunAltitude
        )
        // Bright objects render at the full contrast the sky allows; fainter
        // ones fade out progressively toward the cutoff.
        let duskContrast = SkyBrightness.starContrast(sunAltitudeDegrees: sunAltitude)
        XCTAssertEqual(bright, duskContrast, accuracy: 1e-9)
        XCTAssertGreaterThan(bright, middling)
        XCTAssertGreaterThanOrEqual(middling, faint)
        XCTAssertEqual(faint, 0.0, accuracy: 1e-9)

        // In full daylight the field is still drawn — that is the whole point
        // of a see-through planetarium view — just at reduced contrast.
        let daylightStar = StarAppearance.visibility(
            magnitude: 2.0, fieldOfViewDegrees: 60, sunAltitudeDegrees: 45
        )
        XCTAssertGreaterThan(daylightStar, 0.5, "stars must remain visible in daylight")
        XCTAssertLessThan(daylightStar, 1.0, "but a bright sky should still cost contrast")

        // Venus, far brighter, is at least as visible as an ordinary star.
        XCTAssertGreaterThanOrEqual(
            StarAppearance.visibility(magnitude: -4.2, fieldOfViewDegrees: 60, sunAltitudeDegrees: 45),
            daylightStar
        )

        // The night sky is strictly higher contrast than the day sky.
        XCTAssertGreaterThan(
            StarAppearance.visibility(magnitude: 2.0, fieldOfViewDegrees: 60, sunAltitudeDegrees: -20),
            daylightStar
        )
    }

    // MARK: - Zooming in reveals more stars

    func testZoomingInDeepensTheFieldMonotonicallyToTheCatalogueLimit() throws {
        // Wide field stays legible; the narrow end reaches the bottom of the
        // bundled catalogue so pinching all the way in is not a promise the
        // data cannot keep.
        XCTAssertEqual(StarAppearance.limitingMagnitude(fieldOfViewDegrees: 150), 5.4, accuracy: 1e-9)
        XCTAssertEqual(StarAppearance.limitingMagnitude(fieldOfViewDegrees: 3), 9.0, accuracy: 1e-9)
        // Clamped outside the interpolation range rather than extrapolating.
        XCTAssertEqual(StarAppearance.limitingMagnitude(fieldOfViewDegrees: 200), 5.4, accuracy: 1e-9)
        XCTAssertEqual(StarAppearance.limitingMagnitude(fieldOfViewDegrees: 0.5), 9.0, accuracy: 1e-9)

        // Strictly deeper as you zoom, with no step big enough to see as a pop.
        var previous = StarAppearance.limitingMagnitude(fieldOfViewDegrees: 150)
        // Stepped multiplicatively (a 1% pinch), which is what the gesture
        // actually does — a fixed 1-degree step is a huge zoom at the narrow
        // end and a negligible one at the wide end.
        var fov = 150.0 * 0.99
        while fov >= 3.0 {
            let value = StarAppearance.limitingMagnitude(fieldOfViewDegrees: fov)
            XCTAssertGreaterThanOrEqual(value, previous - 1e-9, "regressed at FOV \(fov)")
            XCTAssertLessThan(value - previous, 0.02, "jumped at FOV \(fov)")
            previous = value
            fov *= 0.99
        }

        // A mid-field check that the curve is doing its interpolation on
        // log(FOV): halving the field from 60 to 30 should buy a similar
        // amount of depth as halving it again from 30 to 15.
        let d1 = StarAppearance.limitingMagnitude(fieldOfViewDegrees: 30)
            - StarAppearance.limitingMagnitude(fieldOfViewDegrees: 60)
        let d2 = StarAppearance.limitingMagnitude(fieldOfViewDegrees: 15)
            - StarAppearance.limitingMagnitude(fieldOfViewDegrees: 30)
        XCTAssertEqual(d1, d2, accuracy: 1e-9)
    }

    // MARK: - Darker sky reveals more stars

    func testDisplayLimitDeepensDramaticallyFromTwilightToNight() throws {
        // The user-visible acceptance criterion: an evening in Fremont. The
        // Sun is still up at 6:20 PM in August (~+15 deg) and a few degrees
        // below the horizon by 8:20 PM.
        let earlyEvening = SkyBrightness.displayLimitingMagnitude(sunAltitudeDegrees: 15)
        let afterSunset = SkyBrightness.displayLimitingMagnitude(sunAltitudeDegrees: -4.5)
        XCTAssertGreaterThan(
            afterSunset - earlyEvening, 1.0,
            "twilight -> night must buy at least a full magnitude of depth"
        )

        // Peak darkness reaches the bottom of the catalogue.
        XCTAssertEqual(
            SkyBrightness.displayLimitingMagnitude(sunAltitudeDegrees: -18),
            SkyBrightness.darkSkyDisplayCeiling,
            accuracy: 0.05
        )
        XCTAssertEqual(
            SkyBrightness.displayLimitingMagnitude(sunAltitudeDegrees: -40),
            SkyBrightness.darkSkyDisplayCeiling,
            accuracy: 1e-9
        )

        // Daylight is unchanged: exactly the floor, so the daytime sky is
        // exactly as dense as it was before this curve existed.
        XCTAssertEqual(
            SkyBrightness.displayLimitingMagnitude(sunAltitudeDegrees: 45),
            SkyBrightness.daylightDisplayFloor,
            accuracy: 0.01
        )

        // Monotonic and smooth all the way down, so scrubbing time never pops.
        var previous = SkyBrightness.displayLimitingMagnitude(sunAltitudeDegrees: 60)
        var alt = 60.0
        while alt >= -30.0 {
            let value = SkyBrightness.displayLimitingMagnitude(sunAltitudeDegrees: alt)
            XCTAssertGreaterThanOrEqual(value, previous - 1e-9, "regressed at Sun altitude \(alt)")
            XCTAssertLessThan(value - previous, 0.15, "stepped at Sun altitude \(alt)")
            previous = value
            alt -= 0.25
        }

        // The physical model is untouched — it must NOT have followed the
        // display curve up to 9.
        XCTAssertLessThan(SkyBrightness.limitingMagnitude(sunAltitudeDegrees: -40), 7.0)
    }

    func testNightIsBothDeeperAndHigherContrastThanTwilight() throws {
        let twilightLimit = SkyBrightness.displayLimitingMagnitude(sunAltitudeDegrees: -4.5)
        let nightLimit = SkyBrightness.displayLimitingMagnitude(sunAltitudeDegrees: -18)
        XCTAssertGreaterThan(nightLimit, twilightLimit)

        let twilightContrast = SkyBrightness.starContrast(sunAltitudeDegrees: -4.5)
        let nightContrast = SkyBrightness.starContrast(sunAltitudeDegrees: -18)
        XCTAssertGreaterThan(nightContrast, twilightContrast)

        // And a star that is invisible in twilight is visible at night, at a
        // field of view narrow enough that the FOV limit is not what binds.
        XCTAssertEqual(
            StarAppearance.visibility(magnitude: 7.5, fieldOfViewDegrees: 8, sunAltitudeDegrees: -4.5),
            0.0, accuracy: 1e-9
        )
        XCTAssertGreaterThan(
            StarAppearance.visibility(magnitude: 7.5, fieldOfViewDegrees: 8, sunAltitudeDegrees: -18),
            0.4
        )
    }
}

final class CelestialDiskSizeTests: XCTestCase {

    func testAngularDiametersMatchPublishedValues() throws {
        // Sun at 1 AU: about 0.533 deg (32 arcmin).
        let sun = StarAppearance.angularDiameterDegrees(
            objectID: "sun", distanceKilometres: 149_597_870.7
        )
        XCTAssertEqual(sun, 0.533, accuracy: 0.005)

        // Moon at its mean distance: about 0.518 deg (31 arcmin).
        let moon = StarAppearance.angularDiameterDegrees(
            objectID: "moon", distanceKilometres: 384_400
        )
        XCTAssertEqual(moon, 0.518, accuracy: 0.005)

        // Jupiter near opposition (~4.2 AU): about 47 arcsec = 0.0131 deg.
        let jupiter = StarAppearance.angularDiameterDegrees(
            objectID: "jupiter", distanceKilometres: 4.2 * 149_597_870.7
        )
        XCTAssertEqual(jupiter * 3600, 47.0, accuracy: 2.0)

        // Stars are unresolvable.
        XCTAssertEqual(
            StarAppearance.angularDiameterDegrees(objectID: "sirius", distanceKilometres: 1e13),
            0.0, accuracy: 1e-12
        )
    }

    func testDiskGrowsLinearlyWithZoomOnceTheTrueSizeDominates() throws {
        let distance = 4.2 * 149_597_870.7
        func size(fov: Double) -> Double {
            Double(StarAppearance.solarSystemPointSize(
                objectID: "jupiter", kind: .planet, magnitude: -2.2,
                distanceKilometres: distance, fieldOfViewDegrees: fov, viewportWidth: 1600
            ))
        }
        // Halving the field of view doubles the disk, well away from both the
        // minimum-size floor and the ceiling.
        let wide = size(fov: 0.5)
        let narrow = size(fov: 0.25)
        XCTAssertEqual(narrow / wide, 2.0, accuracy: 0.05)
    }

    func testDiskSizeIsContinuousAcrossTheMinimumSizeCrossover() throws {
        // Sweep the whole zoom range and assert no step: the smooth-max blend
        // between the floor and the true angular size must not pop.
        // Venus near inferior conjunction, when it is largest.
        let distance = 0.28 * 149_597_870.7
        var fov = 160.0
        var previous = Double(StarAppearance.solarSystemPointSize(
            objectID: "venus", kind: .planet, magnitude: -4.2,
            distanceKilometres: distance, fieldOfViewDegrees: fov, viewportWidth: 1600
        ))
        while fov > 0.05 {
            fov *= 0.999
            let value = Double(StarAppearance.solarSystemPointSize(
                objectID: "venus", kind: .planet, magnitude: -4.2,
                distanceKilometres: distance, fieldOfViewDegrees: fov, viewportWidth: 1600
            ))
            XCTAssertGreaterThanOrEqual(value, previous - 1e-9, "shrank while zooming in at fov \(fov)")
            XCTAssertLessThan(value - previous, 1.0, "visible pop at fov \(fov)")
            previous = value
        }
        // And it really did grow into a resolved disk.
        XCTAssertGreaterThan(previous, 100)
    }

    func testSmoothMaxNeverFallsBelowTheHardMax() throws {
        for a in stride(from: -5.0, through: 5.0, by: 0.25) {
            for b in stride(from: -5.0, through: 5.0, by: 0.25) {
                let smooth = StarAppearance.smoothMax(a, b, softness: 1.0)
                XCTAssertGreaterThanOrEqual(smooth, max(a, b) - 1e-9)
                XCTAssertLessThanOrEqual(smooth, max(a, b) + 0.5 + 1e-9)
            }
        }
    }
}

final class PlanetPhaseTests: XCTestCase {

    func testInferiorPlanetsShowPhasesAndSuperiorPlanetsDoNot() throws {
        let jd = JulianDate.j2000
        let venus = PlanetPosition.state(planet: .venus, julianDay: jd)
        let jupiter = PlanetPosition.state(planet: .jupiter, julianDay: jd)

        XCTAssertTrue((0...1).contains(venus.illuminatedFraction))
        // Jupiter can never be less than ~99% illuminated from Earth.
        XCTAssertGreaterThan(jupiter.illuminatedFraction, 0.98)

        // Distances must be physically sensible.
        XCTAssertEqual(venus.heliocentricDistanceAU, 0.723, accuracy: 0.02)
        XCTAssertTrue((0.25...1.8).contains(venus.geocentricDistanceAU))
        XCTAssertEqual(jupiter.heliocentricDistanceAU, 5.2, accuracy: 0.3)
        XCTAssertTrue((3.9...6.6).contains(jupiter.geocentricDistanceAU))
    }

    func testVenusIsACrescentWhenNearestToEarth() throws {
        // Venus is closest at inferior conjunction, where it is a thin
        // crescent — the phase and the distance must move together.
        var minDistance = Double.infinity
        var kAtMinimum = 1.0
        for day in stride(from: 0.0, through: 600.0, by: 1.0) {
            let s = PlanetPosition.state(planet: .venus, julianDay: JulianDate.j2000 + day)
            if s.geocentricDistanceAU < minDistance {
                minDistance = s.geocentricDistanceAU
                kAtMinimum = s.illuminatedFraction
            }
        }
        XCTAssertLessThan(minDistance, 0.35)
        XCTAssertLessThan(kAtMinimum, 0.05, "Venus at inferior conjunction is a sliver")
    }

    func testMoonAndSunDistancesAreInRange() throws {
        for day in stride(from: 0.0, through: 400.0, by: 1.0) {
            let jd = JulianDate.j2000 + day
            let moon = MoonPosition.distanceKilometres(julianDay: jd)
            XCTAssertTrue((350_000.0...410_000.0).contains(moon), "moon distance \(moon)")
            let sun = SunPosition.radiusVectorAU(julianDay: jd)
            XCTAssertTrue((0.980...1.020).contains(sun), "sun radius vector \(sun)")
        }
    }
}

final class MoonPhaseTests: XCTestCase {

    func testFullMoonAtOppositionIsFullyIlluminated() throws {
        // Opposition: Moon exactly 180 deg from the Sun in RA, same Dec.
        let sun = EquatorialCoordinate(rightAscensionDegrees: 10, declinationDegrees: 5)
        let moon = EquatorialCoordinate(rightAscensionDegrees: 190, declinationDegrees: 5)
        let k = MoonPhase.illuminatedFraction(sun: sun, moon: moon)
        XCTAssertEqual(k, 1.0, accuracy: 0.01)
    }

    func testNewMoonAtConjunctionIsUnilluminated() throws {
        // Conjunction: Moon at (nearly) the same equatorial position as the Sun.
        let sun = EquatorialCoordinate(rightAscensionDegrees: 200, declinationDegrees: -3)
        let moon = EquatorialCoordinate(rightAscensionDegrees: 200, declinationDegrees: -3)
        let k = MoonPhase.illuminatedFraction(sun: sun, moon: moon)
        XCTAssertEqual(k, 0.0, accuracy: 0.01)
    }

    func testQuarterMoonIsHalfIlluminated() throws {
        // 90 deg elongation on the celestial equator gives k = 0.5.
        let sun = EquatorialCoordinate(rightAscensionDegrees: 0, declinationDegrees: 0)
        let moon = EquatorialCoordinate(rightAscensionDegrees: 90, declinationDegrees: 0)
        let k = MoonPhase.illuminatedFraction(sun: sun, moon: moon)
        XCTAssertEqual(k, 0.5, accuracy: 0.01)
    }
}

// MARK: - Spatial index

/// The spatial cull is the one piece of this feature that cannot be checked by
/// eye: a bug that silently deletes real stars would look like a slightly
/// sparser sky, not like a crash. So every test here is differential — the
/// index is compared against the naive full scan it replaces, at orientations
/// chosen to hit the two classic failure modes (the RA = 0/360 wrap, and the
/// poles where RA cells converge).
final class StarIndexTests: XCTestCase {

    /// A synthetic catalogue laid out on a regular grid so it covers every
    /// cell, plus deliberate points exactly on the poles and exactly on the
    /// RA seam. Magnitudes ascend, matching the real catalogue's ordering.
    private static let catalogue: [Star] = {
        var stars: [Star] = []
        var id = 0
        for decIndex in 0...36 {
            let dec = -90.0 + Double(decIndex) * 5.0
            for raIndex in 0..<72 {
                let ra = Double(raIndex) * 5.0 + 2.5
                id += 1
                stars.append(
                    Star(
                        id: id,
                        name: nil,
                        ra: ra,
                        dec: dec,
                        magnitude: Double((id % 100)) / 10.0,   // 0.0 ... 9.9
                        colorIndex: 0.5,
                        spectralType: nil
                    )
                )
            }
        }
        // Exact edge cases the grid must not lose.
        let edges: [(Double, Double)] = [
            (0.0, 90.0), (180.0, 90.0), (0.0, -90.0), (359.999, -90.0),
            (0.0, 0.0), (359.999, 0.0), (360.0, 12.0), (0.0, 89.999)
        ]
        for (ra, dec) in edges {
            id += 1
            stars.append(Star(id: id, name: nil, ra: ra, dec: dec, magnitude: 1.0,
                              colorIndex: nil, spectralType: nil))
        }
        // The index relies on the input being magnitude-ascending to get its
        // per-cell ordering for free, exactly as the real catalogue is.
        return stars.sorted { $0.magnitude < $1.magnitude }
    }()

    private static let index = StarIndex(stars: catalogue)

    /// Every star of the synthetic catalogue survives the bucketing.
    func testIndexPreservesEveryStar() throws {
        XCTAssertEqual(Self.index.stars.count, Self.catalogue.count)
        XCTAssertEqual(
            Set(Self.index.stars.map(\.id)),
            Set(Self.catalogue.map(\.id))
        )
        // Contiguous, non-overlapping cell ranges covering the whole array.
        var expectedStart = 0
        for cell in Self.index.cells {
            XCTAssertEqual(cell.start, expectedStart)
            XCTAssertGreaterThan(cell.count, 0)
            expectedStart += cell.count
        }
        XCTAssertEqual(expectedStart, Self.index.stars.count)
    }

    /// Each cell is magnitude-ascending, which is what makes the early `break`
    /// in the renderer's scan correct rather than merely fast.
    func testCellsAreMagnitudeAscending() throws {
        for cell in Self.index.cells {
            for i in (cell.start + 1)..<(cell.start + cell.count) {
                XCTAssertLessThanOrEqual(
                    Self.index.stars[i - 1].magnitude,
                    Self.index.stars[i].magnitude
                )
            }
        }
    }

    /// The load-bearing test: the cull must be a strict superset of the truth.
    ///
    /// For a spread of camera directions and field sizes, the naive answer
    /// ("every star within theta of the centre, brighter than the limit") must
    /// be entirely contained in what the index yields. Anything extra is
    /// harmless — the projection rejects it a moment later.
    func testCullNeverDropsAStarTheFullScanWouldKeep() throws {
        let directions: [(String, Double, Double)] = [
            ("north celestial pole", 0, 90),
            ("just off the north pole", 137, 88.5),
            ("south celestial pole", 0, -90),
            ("just off the south pole", 300, -87.2),
            ("RA seam, equator", 0, 0),
            ("just below the seam", 359.7, 0),
            ("just above the seam", 0.3, 0),
            ("seam at high dec", 359.9, 76),
            ("seam at low dec", 0.1, -76),
            ("arbitrary A", 83.6, 22.0),
            ("arbitrary B", 201.3, -41.7),
            ("arbitrary C", 297.5, 61.4)
        ]
        let fovs = [150.0, 90.0, 60.0, 30.0, 10.0, 3.0, 1.0]
        let viewports = [CGSize(width: 1600, height: 900), CGSize(width: 800, height: 1400)]
        let limits = [5.4, 6.9, 9.0, 12.0]

        for (label, ra, dec) in directions {
            let center = StarIndex.direction(raDegrees: ra, decDegrees: dec)
            for fov in fovs {
                for viewport in viewports {
                    let theta = StarIndex.fieldAngularRadiusRadians(
                        fieldOfViewDegrees: fov, viewportSize: viewport
                    )
                    for limit in limits {
                        var kept: Set<Int> = []
                        Self.index.forEachCandidate(
                            centerDirection: center,
                            angularRadiusRadians: theta,
                            magnitudeLimit: limit
                        ) { kept.insert($0.id) }

                        // The naive scan the index is standing in for. Note it
                        // uses a *smaller* cone than the index is allowed to:
                        // theta with no padding at all, so any slack in the
                        // index's bounds can only help it.
                        let cosTheta = cos(theta)
                        for star in Self.catalogue where star.magnitude < limit {
                            let d = StarIndex.direction(raDegrees: star.ra, decDegrees: star.dec)
                            guard simd_dot(d, center) >= cosTheta else { continue }
                            XCTAssertTrue(
                                kept.contains(star.id),
                                "dropped star \(star.id) at RA \(star.ra) Dec \(star.dec) "
                                + "looking at \(label), FOV \(fov), limit \(limit)"
                            )
                        }
                    }
                }
            }
        }
    }

    /// And it has to actually pay for itself: a narrow field must consider a
    /// small fraction of the sky even at the deepest magnitude limit.
    func testCullMeaningfullyReducesTheCandidateCountAtNarrowField() throws {
        let center = StarIndex.direction(raDegrees: 83.6, decDegrees: 22.0)
        let viewport = CGSize(width: 1600, height: 900)
        let total = Self.catalogue.count

        func candidates(fov: Double, limit: Double) -> Int {
            Self.index.candidateCount(
                centerDirection: center,
                angularRadiusRadians: StarIndex.fieldAngularRadiusRadians(
                    fieldOfViewDegrees: fov, viewportSize: viewport
                ),
                magnitudeLimit: limit
            )
        }

        // Deepest limit, narrow field: the spatial cut is doing all the work.
        XCTAssertLessThan(Double(candidates(fov: 3, limit: 9.5)), Double(total) * 0.02)
        XCTAssertLessThan(Double(candidates(fov: 10, limit: 9.5)), Double(total) * 0.06)
        XCTAssertLessThan(Double(candidates(fov: 30, limit: 9.5)), Double(total) * 0.25)
        // Zooming in must never make it consider more.
        XCTAssertLessThanOrEqual(candidates(fov: 3, limit: 9.5), candidates(fov: 10, limit: 9.5))
        XCTAssertLessThanOrEqual(candidates(fov: 10, limit: 9.5), candidates(fov: 60, limit: 9.5))
        // Whole sky on screen: nothing is culled spatially, and the magnitude
        // cut is what keeps it cheap.
        XCTAssertLessThan(Double(candidates(fov: 150, limit: 5.4)), Double(total) * 0.6)
    }

    /// A 180-degree-plus cone must degrade to "keep everything" rather than
    /// wrapping around and rejecting the far hemisphere.
    func testFullSkyConeKeepsEverything() throws {
        let center = StarIndex.direction(raDegrees: 12.0, decDegrees: -30.0)
        let count = Self.index.candidateCount(
            centerDirection: center,
            angularRadiusRadians: .pi,
            magnitudeLimit: 100
        )
        XCTAssertEqual(count, Self.catalogue.count)
    }

    /// The real bundled catalogue: the index must not lose a star of it, and
    /// a narrow field must be a small slice.
    ///
    /// Decoded synchronously and directly from the bundle rather than through
    /// `CatalogService`. That is deliberate: an `async` test yields the main
    /// thread, which lets the test *host application* finish launching its
    /// Metal view mid-test, and the host has a pre-existing startup crash
    /// (`pointer being freed was not allocated`) that is reproducible on an
    /// unmodified checkout and has nothing to do with this code. Staying
    /// synchronous keeps the suite green and the bug where it belongs.
    func testBundledCatalogueIndexesConsistently() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "stars", withExtension: "json"))
        let stars = try JSONDecoder().decode([Star].self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(stars.count, 50_000, "expected the deep HYG catalogue")

        let index = StarIndex(stars: stars)
        XCTAssertEqual(index.stars.count, stars.count)

        let center = StarIndex.direction(raDegrees: 83.6, decDegrees: 22.0)
        let theta = StarIndex.fieldAngularRadiusRadians(
            fieldOfViewDegrees: 3, viewportSize: CGSize(width: 1600, height: 900)
        )
        var kept: Set<Int> = []
        index.forEachCandidate(
            centerDirection: center, angularRadiusRadians: theta, magnitudeLimit: 9.5
        ) { kept.insert($0.id) }

        // Subsampled naive scan: enough of the real catalogue to catch a
        // systematic culling error without 83,000 trig calls of test time.
        let cosTheta = cos(theta)
        var checked = 0
        for i in stride(from: 0, to: stars.count, by: 5) {
            let star = stars[i]
            guard star.magnitude < 9.5 else { continue }
            let d = StarIndex.direction(raDegrees: star.ra, decDegrees: star.dec)
            guard simd_dot(d, center) >= cosTheta else { continue }
            checked += 1
            XCTAssertTrue(kept.contains(star.id), "dropped catalogue star \(star.id)")
        }
        XCTAssertGreaterThan(checked, 10, "the sample must actually cover the field")
        XCTAssertLessThan(kept.count, stars.count / 50)
    }
}

// MARK: - Deep-sky catalogue and rendering

/// The bundled deep-sky catalogue and the geometry that turns an angular
/// extent into a screen size.
///
/// Decoded synchronously and directly from the bundle rather than through
/// `CatalogService`, for the reason documented on
/// `testBundledCatalogueIndexesConsistently`: an `async` test lets the test
/// *host application* finish launching mid-test, and the host has a
/// pre-existing startup crash unrelated to any of this.
final class DeepSkyCatalogueTests: XCTestCase {

    private func loadCatalogue() throws -> [DeepSkyObject] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "deepsky", withExtension: "json"))
        return try JSONDecoder().decode([DeepSkyObject].self, from: Data(contentsOf: url))
    }

    func testBundledDeepSkyCatalogueDecodes() throws {
        let objects = try loadCatalogue()
        XCTAssertGreaterThan(objects.count, 800, "expected the full OpenNGC-derived selection")
        // Dark nebulae are absorption features and must not be drawn; the
        // selection should not contain any in the first place.
        XCTAssertFalse(objects.contains { $0.type == .darkNebula })
        // Sorted magnitude-ascending, which the loader and the renderer both
        // assume when they talk about "the brightest few".
        XCTAssertEqual(objects.map(\.magnitude), objects.map(\.magnitude).sorted())
    }

    func testFamousObjectsArePresentAtTheirPublishedCoordinates() throws {
        let objects = try loadCatalogue()
        let byDesignation = Dictionary(objects.map { ($0.catalogName, $0) }, uniquingKeysWith: { a, _ in a })

        // J2000 positions, NED / OpenNGC.
        let m31 = try XCTUnwrap(byDesignation["M31"])
        XCTAssertEqual(m31.name, "Andromeda Galaxy")
        XCTAssertEqual(m31.type, .galaxy)
        XCTAssertEqual(m31.ra, 10.6848, accuracy: 0.01)     // 00h 42m 44s
        XCTAssertEqual(m31.dec, 41.2691, accuracy: 0.01)    // +41d 16'
        XCTAssertEqual(m31.magnitude, 3.44, accuracy: 0.2)
        XCTAssertEqual(try XCTUnwrap(m31.majorAxisArcmin), 177.8, accuracy: 1.0)

        let m45 = try XCTUnwrap(byDesignation["M45"])
        XCTAssertEqual(m45.name, "Pleiades")
        XCTAssertEqual(m45.ra, 56.869, accuracy: 0.05)      // 03h 47m
        XCTAssertEqual(m45.dec, 24.105, accuracy: 0.05)     // +24d 06'

        let m42 = try XCTUnwrap(byDesignation["M42"])
        XCTAssertEqual(m42.ra, 83.819, accuracy: 0.05)      // 05h 35m 17s
        XCTAssertEqual(m42.dec, -5.390, accuracy: 0.05)     // -05d 23'
        // OpenNGC types M42 "Cl+N"; it must still be *drawn* as a nebula.
        XCTAssertEqual(m42.renderType, .nebula)

        // Every Messier object is meant to be in here.
        let messier = objects.filter { $0.catalogName.hasPrefix("M") && Int($0.catalogName.dropFirst()) != nil }
        XCTAssertGreaterThanOrEqual(messier.count, 100)
    }

    func testAndromedaSpansASensibleFractionOfTheScreen() throws {
        let width = 1600.0
        // 177.8 arcmin is 2.963 deg, so at a 60 deg field it should occupy
        // 2.963/60 = 4.9% of the screen width.
        let size = StarAppearance.deepSkyPointSize(
            majorAxisArcmin: 177.83, fieldOfViewDegrees: 60, viewportWidth: width
        )
        XCTAssertEqual(Double(size) / width, 177.83 / 60.0 / 60.0, accuracy: 0.004)
        XCTAssertGreaterThan(Double(size), 60, "M31 must read as an object, not a dot")

        // Linear in the zoom factor once the true size dominates.
        let zoomed = StarAppearance.deepSkyPointSize(
            majorAxisArcmin: 177.83, fieldOfViewDegrees: 30, viewportWidth: width
        )
        XCTAssertEqual(Double(zoomed) / Double(size), 2.0, accuracy: 0.05)
    }

    func testMinimumSizeAppliesToSmallObjectsAtWideField() throws {
        // A 1-arcmin planetary at a 120 deg field projects to well under a
        // point; the floor keeps it visible and clickable.
        let tiny = StarAppearance.deepSkyPointSize(
            majorAxisArcmin: 1.0, fieldOfViewDegrees: 120, viewportWidth: 1600
        )
        XCTAssertGreaterThanOrEqual(Double(tiny), StarAppearance.deepSkyMinimumSize)
        XCTAssertLessThan(Double(tiny), StarAppearance.deepSkyMinimumSize * 2)

        // Missing size data also falls back to the floor rather than zero.
        let unknown = StarAppearance.deepSkyPointSize(
            majorAxisArcmin: nil, fieldOfViewDegrees: 60, viewportWidth: 1600
        )
        XCTAssertGreaterThanOrEqual(Double(unknown), StarAppearance.deepSkyMinimumSize)

        // The size curve is monotonic in the true extent.
        let small = StarAppearance.deepSkyPointSize(
            majorAxisArcmin: 5, fieldOfViewDegrees: 20, viewportWidth: 1600
        )
        let large = StarAppearance.deepSkyPointSize(
            majorAxisArcmin: 25, fieldOfViewDegrees: 20, viewportWidth: 1600
        )
        XCTAssertGreaterThan(large, small)
        // And it never exceeds the GPU's point-size ceiling.
        let huge = StarAppearance.deepSkyPointSize(
            majorAxisArcmin: 646, fieldOfViewDegrees: 1, viewportWidth: 1600
        )
        XCTAssertLessThanOrEqual(Double(huge), 500)
    }

    func testAxisRatioSquashesGalaxiesAndFallsBackToACircle() throws {
        XCTAssertEqual(
            StarAppearance.deepSkyAxisRatio(majorAxisArcmin: 177.83, minorAxisArcmin: 69.66),
            0.3917, accuracy: 0.001
        )
        XCTAssertEqual(StarAppearance.deepSkyAxisRatio(majorAxisArcmin: 10, minorAxisArcmin: nil), 1.0)
        XCTAssertEqual(StarAppearance.deepSkyAxisRatio(majorAxisArcmin: nil, minorAxisArcmin: nil), 1.0)
        // Edge-on discs are floored so they stay a few pixels wide.
        XCTAssertEqual(
            StarAppearance.deepSkyAxisRatio(majorAxisArcmin: 100, minorAxisArcmin: 1),
            0.12, accuracy: 1e-9
        )
    }

    /// The surface-brightness bias is an approximation (see
    /// `deepSkyDetectionMagnitude`): bounded, so the famous large objects
    /// survive a wide field while faint ones still need zoom.
    func testSurfaceBrightnessPenaltyIsBoundedAndOrdered() throws {
        let m31 = StarAppearance.deepSkyDetectionMagnitude(
            magnitude: 3.44, majorAxisArcmin: 177.83, minorAxisArcmin: 69.66
        )
        XCTAssertEqual(m31, 4.64, accuracy: 0.01, "penalty must saturate at 1.2 mag")

        // A compact object of the same integrated magnitude is penalised less.
        let compact = StarAppearance.deepSkyDetectionMagnitude(
            magnitude: 3.44, majorAxisArcmin: 4, minorAxisArcmin: 4
        )
        XCTAssertEqual(compact, 3.44, accuracy: 1e-9)
        XCTAssertLessThan(compact, m31)

        // M31 and M45 are visible at a wide field on a dark night; a faint
        // small galaxy is not, and needs zoom to appear.
        let night = -20.0
        XCTAssertGreaterThan(
            StarAppearance.visibility(magnitude: m31, fieldOfViewDegrees: 90, sunAltitudeDegrees: night), 0.2
        )
        let m45 = StarAppearance.deepSkyDetectionMagnitude(
            magnitude: 1.2, majorAxisArcmin: 150, minorAxisArcmin: 150
        )
        XCTAssertGreaterThan(
            StarAppearance.visibility(magnitude: m45, fieldOfViewDegrees: 90, sunAltitudeDegrees: night), 0.5
        )

        let faint = StarAppearance.deepSkyDetectionMagnitude(
            magnitude: 8.5, majorAxisArcmin: 3, minorAxisArcmin: 2
        )
        XCTAssertEqual(
            StarAppearance.visibility(magnitude: faint, fieldOfViewDegrees: 90, sunAltitudeDegrees: night), 0.0
        )
        XCTAssertGreaterThan(
            StarAppearance.visibility(magnitude: faint, fieldOfViewDegrees: 4, sunAltitudeDegrees: night), 0.0
        )

        // Nothing is drawn in daylight. Deep-sky objects take the same
        // visibility path the stars take — no planet-style exemption — and are
        // then additionally suppressed through twilight, because the star
        // path's deliberate daylight floor is wrong for extended objects.
        XCTAssertEqual(StarAppearance.deepSkyTwilightFactor(sunAltitudeDegrees: 40), 0.0)
        XCTAssertEqual(StarAppearance.deepSkyTwilightFactor(sunAltitudeDegrees: 0), 0.0)
        XCTAssertGreaterThan(StarAppearance.deepSkyTwilightFactor(sunAltitudeDegrees: -8), 0.0)
        XCTAssertLessThan(StarAppearance.deepSkyTwilightFactor(sunAltitudeDegrees: -8), 1.0)
        XCTAssertEqual(StarAppearance.deepSkyTwilightFactor(sunAltitudeDegrees: -14), 1.0)
    }

    /// Mirrors `SkyViewModel.updateSearchResults`' deep-sky matching rule:
    /// common name *or* catalogue designation, whitespace-insensitive.
    private func matches(_ query: String, in objects: [DeepSkyObject]) -> [DeepSkyObject] {
        let lowered = query.lowercased()
        let condensed = lowered.replacingOccurrences(of: " ", with: "")
        return objects.filter { object in
            if let name = object.name?.lowercased(), name.contains(lowered) { return true }
            let designation = object.catalogName.lowercased().replacingOccurrences(of: " ", with: "")
            return designation.contains(condensed) || object.id.lowercased().contains(condensed)
        }
    }

    /// The Milky Way panorama must be bundled and must be 2:1
    /// equirectangular, which is what the shader's galactic-coordinate lookup
    /// assumes. See DATA_SOURCES.md for source, credit and licence.
    func testMilkyWayPanoramaIsBundledAndEquirectangular() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "milkyway_panorama", withExtension: "jpg"))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        XCTAssertEqual(Double(width) / Double(height), 2.0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(width, 2048)
    }

    func testSearchFindsObjectsByCommonNameAndByDesignation() throws {
        let objects = try loadCatalogue()

        XCTAssertTrue(matches("Andromeda", in: objects).contains { $0.catalogName == "M31" })
        XCTAssertTrue(matches("M31", in: objects).contains { $0.catalogName == "M31" })
        XCTAssertTrue(matches("Pleiades", in: objects).contains { $0.catalogName == "M45" })
        XCTAssertTrue(matches("m45", in: objects).contains { $0.catalogName == "M45" })
        XCTAssertTrue(matches("Orion Nebula", in: objects).contains { $0.catalogName == "M42" })
        // Designation matching ignores the space in "NGC 7000".
        XCTAssertTrue(matches("NGC 7000", in: objects).contains { $0.id == "NGC7000" })
        XCTAssertTrue(matches("ngc7000", in: objects).contains { $0.id == "NGC7000" })

        // The bridge to the selectable/searchable model keeps both spellings.
        let m31 = try XCTUnwrap(objects.first { $0.catalogName == "M31" }).asCelestialObject
        XCTAssertEqual(m31.id, "dso-NGC0224")
        XCTAssertEqual(m31.name, "Andromeda Galaxy")
        XCTAssertEqual(m31.catalogDesignation, "M31")
        XCTAssertEqual(m31.kind, .deepSky)
        XCTAssertEqual(m31.deepSkyType, .galaxy)
    }
}

/// The "see-through Earth" skyline.
///
/// The profile is implemented twice — `TerrainProfile.swift` (which decides
/// which objects are hidden) and `Shaders.metal` (which paints the band). These
/// tests pin the Swift side hard, so an edit to the Metal copy that is not
/// mirrored back here shows up as a failure rather than as objects silently
/// clipping against a skyline that is not where it is drawn.
final class TerrainProfileTests: XCTestCase {

    /// Exactly periodic over a full turn: all four frequencies are integers, so
    /// there can be no seam at due north.
    func testProfileIsPeriodicOverAFullTurn() {
        for az in stride(from: 0.0, through: 359.0, by: 1.0) {
            XCTAssertEqual(
                TerrainProfile.skylineAltitudeDegrees(azimuthDegrees: az),
                TerrainProfile.skylineAltitudeDegrees(azimuthDegrees: az + 360.0),
                accuracy: 1e-9
            )
        }
        XCTAssertEqual(
            TerrainProfile.skylineAltitudeDegrees(azimuthDegrees: 0),
            TerrainProfile.skylineAltitudeDegrees(azimuthDegrees: 360),
            accuracy: 1e-12,
            "a discontinuity at azimuth 0 would draw a visible seam at north"
        )
    }

    /// Continuous, and gentle: no step anywhere, and never outside the
    /// amplitude budget of rolling hills.
    func testProfileIsContinuousAndStaysWithinItsAmplitude() {
        let limit = TerrainProfile.maxAmplitude
        XCTAssertEqual(limit, 2.15, accuracy: 1e-12)

        var previous = TerrainProfile.skylineAltitudeDegrees(azimuthDegrees: 0)
        for step in 1...3600 {
            let value = TerrainProfile.skylineAltitudeDegrees(azimuthDegrees: Double(step) * 0.1)
            XCTAssertLessThanOrEqual(abs(value), limit + 1e-9)
            XCTAssertLessThan(abs(value - previous), 0.05,
                              "the skyline must not step; it is a sum of smooth sinusoids")
            previous = value
        }
    }

    /// Mean skyline sits at altitude 0 — every term is a zero-mean sinusoid, so
    /// no constant offset is needed, and this is what keeps the horizon where a
    /// user expects it.
    func testMeanSkylineIsAtAltitudeZero() {
        var sum = 0.0
        let samples = 3600
        for i in 0..<samples {
            sum += TerrainProfile.skylineAltitudeDegrees(azimuthDegrees: Double(i) * 360.0 / Double(samples))
        }
        XCTAssertEqual(sum / Double(samples), 0.0, accuracy: 1e-9)
    }

    /// Fixed azimuths, pinned to ten decimal places. If the Metal copy is
    /// edited without mirroring it here (or vice versa), this is the tripwire.
    func testProfileMatchesExpectedValuesAtFixedAzimuths() {
        let expected: [(Double, Double)] = [
            (0.0,   1.1180474163),
            (45.0,  0.3282378629),
            (90.0,  0.6070187494),
            (135.0, 0.0652278258),
            (180.0, -0.0134415922),
            (225.0, -0.7971152171),
            (270.0, -1.7116245735),
            (315.0, 0.4036495284),
        ]
        for (azimuth, value) in expected {
            XCTAssertEqual(
                TerrainProfile.skylineAltitudeDegrees(azimuthDegrees: azimuth),
                value,
                accuracy: 1e-9,
                "terrain profile changed at azimuth \(azimuth) — mirror the edit into Shaders.metal"
            )
        }
    }

    /// The occlusion rule in one test: visible above the skyline, hidden inside
    /// the band, visible again below it, because you are looking through the
    /// Earth.
    func testOnlyTheBandOccludes() {
        for azimuth in stride(from: 0.0, to: 360.0, by: 7.0) {
            let skyline = TerrainProfile.skylineAltitudeDegrees(azimuthDegrees: azimuth)
            let thickness = TerrainProfile.bandThicknessDegrees

            XCTAssertFalse(
                TerrainProfile.isOccluded(altitudeDegrees: skyline + 5.0, azimuthDegrees: azimuth),
                "an object well above the skyline must be visible")
            XCTAssertTrue(
                TerrainProfile.isOccluded(altitudeDegrees: skyline - thickness * 0.5, azimuthDegrees: azimuth),
                "an object inside the terrain band must be hidden")
            XCTAssertFalse(
                TerrainProfile.isOccluded(altitudeDegrees: skyline - thickness - 5.0, azimuthDegrees: azimuth),
                "an object below the band must be visible again")
        }
    }

    /// Dimming is 1 above the skyline, eases smoothly in below the band, and
    /// bottoms out at the chosen factor — never zero, because the point of the
    /// feature is that the hidden sky stays rich.
    func testDimmingEasesInBelowTheBandAndNeverReachesZero() {
        let azimuth = 123.0
        let skyline = TerrainProfile.skylineAltitudeDegrees(azimuthDegrees: azimuth)
        let bottom = skyline - TerrainProfile.bandThicknessDegrees

        XCTAssertEqual(TerrainProfile.dimming(altitudeDegrees: skyline + 10, azimuthDegrees: azimuth),
                       1.0, accuracy: 1e-12)
        XCTAssertEqual(TerrainProfile.dimming(altitudeDegrees: bottom, azimuthDegrees: azimuth),
                       1.0, accuracy: 1e-9, "the dimming must start at the band's bottom edge")
        XCTAssertEqual(
            TerrainProfile.dimming(altitudeDegrees: bottom - TerrainProfile.dimmingEaseDegrees, azimuthDegrees: azimuth),
            TerrainProfile.belowHorizonDimming, accuracy: 1e-9)
        XCTAssertEqual(TerrainProfile.dimming(altitudeDegrees: -85, azimuthDegrees: azimuth),
                       TerrainProfile.belowHorizonDimming, accuracy: 1e-9)

        // Monotonic and continuous through the ease-in.
        var previous = 1.0
        for i in 0...200 {
            let alt = bottom - Double(i) * 0.05
            let value = TerrainProfile.dimming(altitudeDegrees: alt, azimuthDegrees: azimuth)
            XCTAssertLessThanOrEqual(value, previous + 1e-12)
            XCTAssertGreaterThanOrEqual(value, TerrainProfile.belowHorizonDimming - 1e-12)
            previous = value
        }
        XCTAssertGreaterThan(TerrainProfile.belowHorizonDimming, 0.4,
                             "sub-horizon detail must stay clearly legible")
    }
}

final class CardinalPointTests: XCTestCase {

    /// The compass rose must agree with the azimuth convention the rest of the
    /// app uses: measured from north, increasing eastward.
    func testCompassRoseUsesCompassConvention() throws {
        let expected: [(String, Double)] = [
            ("N", 0), ("NE", 45), ("E", 90), ("SE", 135),
            ("S", 180), ("SW", 225), ("W", 270), ("NW", 315),
        ]
        let actual = SkyGeometryBuilder.compassPointsForTesting
        XCTAssertEqual(actual.count, expected.count)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a.text, e.0)
            XCTAssertEqual(a.azimuth, e.1, accuracy: 1e-9)
        }
    }

    /// The north point of the horizon must lie directly below the north
    /// celestial pole — that is what makes "N" geographically true rather than
    /// an arbitrary label. Checked by confirming that a star on the meridian
    /// at the pole's azimuth comes back at azimuth 0.
    func testNorthPointLiesUnderTheCelestialPole() throws {
        let jd = JulianDate.julianDay(from: Date())
        for latitude in [10.0, 37.5, 60.0] {
            let observer = GeographicLocation(latitudeDegrees: latitude, longitudeDegrees: -122.0)
            let pole = EquatorialCoordinate(rightAscensionDegrees: 0, declinationDegrees: 90)
            let horizontal = CoordinateTransformService.horizontal(
                from: pole, observer: observer, julianDay: jd
            )
            XCTAssertEqual(horizontal.azimuthDegrees, 0.0, accuracy: 0.5,
                           "the celestial pole must sit due north at latitude \(latitude)")
            XCTAssertEqual(horizontal.altitudeDegrees, latitude, accuracy: 0.01)
        }
    }

    /// A star rising due east crosses the horizon at azimuth 90, and the
    /// equinox point is the textbook case: declination 0 rises exactly east
    /// for any observer.
    func testCelestialEquatorRisesDueEast() throws {
        let jd = JulianDate.julianDay(from: Date())
        let observer = GeographicLocation(latitudeDegrees: 37.5, longitudeDegrees: -122.0)
        let lst = CoordinateTransformService.localSiderealTimeDegrees(
            julianDay: jd, longitudeDegrees: observer.longitudeDegrees
        )
        // Six hours of hour angle before transit puts a dec-0 object on the
        // eastern horizon.
        let equatorial = EquatorialCoordinate(
            rightAscensionDegrees: Angle.normalizeDegrees(lst + 90),
            declinationDegrees: 0
        )
        let horizontal = CoordinateTransformService.horizontal(
            from: equatorial, observer: observer, julianDay: jd
        )
        XCTAssertEqual(horizontal.altitudeDegrees, 0.0, accuracy: 0.5)
        XCTAssertEqual(horizontal.azimuthDegrees, 90.0, accuracy: 0.5)
    }
}
