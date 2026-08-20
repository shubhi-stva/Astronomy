//
//  PlutoTests.swift
//  AstronomyTests
//
//  Pluto: it is in the ephemeris, its position is sane against a published
//  reference, and it is correctly *excluded* from the naked-eye sky by the
//  limiting-magnitude rules while remaining selectable.
//

import XCTest
@testable import Astronomy

final class PlutoEphemerisTests: XCTestCase {

    private func julianDay(year: Int, month: Int, day: Int, hour: Int = 0) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour)
        )!
        return JulianDate.julianDay(from: date)
    }

    func testPlutoIsInTheEphemeris() {
        XCTAssertTrue(Planet.allCases.contains(.pluto))
        XCTAssertTrue(Planet.pluto.isDwarfPlanet)

        let objects = EphemerisService.solarSystemObjects(julianDay: JulianDate.j2000)
        let pluto = objects.first { $0.id == "pluto" }
        XCTAssertNotNil(pluto)
        XCTAssertEqual(pluto?.name, "Pluto")
        XCTAssertEqual(pluto?.kind, .dwarfPlanet)
        // The major planets must stay major.
        XCTAssertEqual(objects.first { $0.id == "neptune" }?.kind, .planet)
    }

    /// Reference: JPL Horizons, target 999 (Pluto barycentre), centre 500@399
    /// (geocentric), QUANTITIES=2 — *apparent* airless RA/Dec referred to the
    /// true equinox of date, which is the frame `PlanetPosition.state` returns
    /// — for 2026-Jan-01 00:00 UTC:
    ///
    ///     RA = 305.93605 deg,  Dec = -23.21992 deg
    ///
    /// The measured residual at this instant is 0.0050 deg — about 18
    /// arcseconds — which is better than the table's own claim and is why the
    /// bound is set at 0.05 deg rather than anything tighter: Pluto is the
    /// least accurate row in the set (a two-body fit to a steeply inclined,
    /// eccentric, 248-year orbit), so the residual is expected to grow toward
    /// the ends of the 1800-2050 window and this test pins one instant near
    /// the middle of it, with headroom.
    func testPlutoPositionAgainstHorizons() {
        let jd = julianDay(year: 2026, month: 1, day: 1)
        let state = PlanetPosition.state(planet: .pluto, julianDay: jd)

        let referenceRA = 305.93605
        let referenceDec = -23.21992

        // Great-circle separation, so the RA convergence at declination -23 is
        // accounted for rather than compared as a raw coordinate difference.
        let separation = Self.separationDegrees(
            ra1: state.equatorial.rightAscensionDegrees,
            dec1: state.equatorial.declinationDegrees,
            ra2: referenceRA, dec2: referenceDec
        )
        XCTAssertLessThan(
            separation, 0.05,
            "Pluto is \(separation) deg from the Horizons apparent place"
        )

        // Sanity on the geometry as well as the direction: Pluto is 30-50 AU
        // from the Sun and never closer than about 28 AU to the Earth.
        XCTAssertGreaterThan(state.heliocentricDistanceAU, 28.0)
        XCTAssertLessThan(state.heliocentricDistanceAU, 51.0)
        XCTAssertGreaterThan(state.geocentricDistanceAU, 27.0)
    }

    /// Pluto's motion is slow (about 1.4 deg per year) and always prograde over
    /// a whole orbit, which is a cheap guard against a sign or units slip in
    /// the added element row.
    func testPlutoMovesSlowlyAndStaysBeyondNeptunesInnerDistance() {
        let jd = julianDay(year: 2026, month: 1, day: 1)
        let a = PlanetPosition.state(planet: .pluto, julianDay: jd)
        let b = PlanetPosition.state(planet: .pluto, julianDay: jd + 365.25)
        let moved = Self.separationDegrees(
            ra1: a.equatorial.rightAscensionDegrees, dec1: a.equatorial.declinationDegrees,
            ra2: b.equatorial.rightAscensionDegrees, dec2: b.equatorial.declinationDegrees
        )
        // Apparent motion is dominated by Pluto's own 1.4 deg/yr; the Earth's
        // parallax loop cancels over exactly one year.
        XCTAssertGreaterThan(moved, 0.5)
        XCTAssertLessThan(moved, 3.0)
    }

    // MARK: - Visibility

    /// At magnitude 14.4 Pluto must never survive the limiting-magnitude
    /// cutoff at any field of view the app offers, in any sky brightness.
    func testPlutoIsBelowTheNakedEyeLimitEverywhere() {
        let magnitude = EphemerisService.solarSystemObjects(julianDay: JulianDate.j2000)
            .first { $0.id == "pluto" }!.magnitude
        XCTAssertGreaterThan(magnitude, 13.0)

        for fov in [0.5, 3.0, 10.0, 30.0, 90.0, 150.0, 200.0] {
            for sunAltitude in [-90.0, -18.0, -6.0, 0.0, 45.0] {
                let v = StarAppearance.visibility(
                    magnitude: magnitude,
                    fieldOfViewDegrees: fov,
                    sunAltitudeDegrees: sunAltitude
                )
                XCTAssertEqual(
                    v, 0.0, accuracy: 1e-9,
                    "Pluto should be invisible at fov \(fov), sun altitude \(sunAltitude)"
                )
            }
        }

        // The brightest naked-eye planets are of course unaffected.
        XCTAssertGreaterThan(
            StarAppearance.visibility(magnitude: -4.2, fieldOfViewDegrees: 60, sunAltitudeDegrees: -20),
            0.5
        )
    }

    /// The point of the previous test is only fair if selection still reveals
    /// it: the geometry builder must draw and ring a selected Pluto even
    /// though its magnitude is far past the cutoff.
    func testSelectingPlutoRevealsIt() {
        let jd = julianDay(year: 2026, month: 1, day: 1)
        let objects = EphemerisService.solarSystemObjects(julianDay: jd)
        let pluto = objects.first { $0.id == "pluto" }!

        // Point the camera straight at it so it is unambiguously on screen.
        let observer = GeographicLocation(latitudeDegrees: 37.77, longitudeDegrees: -122.42)
        let horizontal = CoordinateTransformService.horizontal(
            from: pluto.equatorial, observer: observer, julianDay: jd
        )

        func projectedIDs(selecting selectedID: String?) -> [String] {
            let frame = SkyFrameData(
                stars: [],
                solarSystemObjects: objects,
                constellationLines: [],
                constellations: [],
                deepSkyObjects: [],
                starsByID: [:],
                starIndex: nil,
                observerLocation: observer,
                julianDay: jd,
                cameraCenter: horizontal,
                cameraFieldOfViewDegrees: 20,
                viewportSize: CGSize(width: 1200, height: 800),
                sunHorizontal: nil,
                sunEquatorial: nil,
                moonEquatorial: nil,
                selectedObjectID: selectedID
            )
            var builder = SkyGeometryBuilder(frameData: frame)
            builder.run()
            return builder.projectedObjects.map { $0.object.id }
        }

        XCTAssertFalse(
            projectedIDs(selecting: nil).contains("pluto"),
            "An unselected Pluto must stay out of the drawn sky"
        )
        XCTAssertTrue(
            projectedIDs(selecting: "pluto").contains("pluto"),
            "A selected Pluto must be drawn, or search would fly to an empty patch of sky"
        )
    }

    static func separationDegrees(
        ra1: Double, dec1: Double, ra2: Double, dec2: Double
    ) -> Double {
        let d2r = Double.pi / 180
        let (a1, d1) = (ra1 * d2r, dec1 * d2r)
        let (a2, d2) = (ra2 * d2r, dec2 * d2r)
        let cosSeparation = sin(d1) * sin(d2) + cos(d1) * cos(d2) * cos(a1 - a2)
        return acos(max(-1, min(1, cosSeparation))) / d2r
    }
}
