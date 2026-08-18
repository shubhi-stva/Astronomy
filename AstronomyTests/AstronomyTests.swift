//
//  AstronomyTests.swift
//  AstronomyTests
//
//  Unit tests for the pure calculation layer: Julian Date conversion,
//  RA/Dec -> Alt/Az transform, and a Sun-position sanity check against a
//  published reference value.
//

import XCTest
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
        XCTAssertEqual(day, SkyBrightness.daylightDisplayFloor, accuracy: 1e-9)
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
        // is ~5.16 and the fade spans the magnitude below it, so 4.6 is
        // partway through the fade and 5.3 is past the cutoff entirely.
        let middling = StarAppearance.visibility(
            magnitude: 4.6, fieldOfViewDegrees: 60, sunAltitudeDegrees: sunAltitude
        )
        let faint = StarAppearance.visibility(
            magnitude: 5.3, fieldOfViewDegrees: 60, sunAltitudeDegrees: sunAltitude
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
