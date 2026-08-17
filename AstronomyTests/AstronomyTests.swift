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
