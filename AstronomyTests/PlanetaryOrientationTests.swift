//
//  PlanetaryOrientationTests.swift
//  AstronomyTests
//
//  The sub-Earth point drives which hemisphere of a bundled surface map is
//  drawn. Getting it wrong would show the user detail that looks convincing
//  and is in the wrong place, which is worse than showing no detail at all —
//  so the properties that make it right are asserted here rather than trusted.
//
//  These are physical checks (rotation periods, tidal locking, axial tilt),
//  not regression snapshots of whatever the code happened to return.
//

import XCTest
import simd
@testable import Astronomy

final class PlanetaryOrientationTests: XCTestCase {

    /// 2026 August 26, 00:00 UTC.
    private let referenceJD = 2_461_278.5

    private func marsAt(_ jd: Double, ra: Double = 120.0, dec: Double = 20.0)
    -> PlanetaryOrientation.Orientation? {
        PlanetaryOrientation.orientation(
            objectID: "mars",
            equatorial: EquatorialCoordinate(rightAscensionDegrees: ra, declinationDegrees: dec),
            julianDay: jd
        )
    }

    // MARK: - Which bodies are covered

    func testOnlyTheThreeMappedBodiesHaveRotationElements() {
        for id in ["mars", "jupiter", "moon"] {
            XCTAssertNotNil(PlanetaryOrientation.rotationElements(objectID: id), id)
            XCTAssertTrue(PlanetaryOrientation.hasSurfaceMap(objectID: id), id)
        }
        for id in ["mercury", "venus", "saturn", "uranus", "neptune", "sun", "pluto", "sirius"] {
            XCTAssertNil(PlanetaryOrientation.rotationElements(objectID: id), id)
            XCTAssertFalse(PlanetaryOrientation.hasSurfaceMap(objectID: id), id)
        }
    }

    func testEveryMappedBodyHasATextureSliceAndViceVersa() {
        // The two tables must agree, or a body gets a map with no orientation
        // (features in the wrong place) or an orientation with no map.
        for entry in PlanetSurfaceMaps.entries {
            XCTAssertTrue(
                PlanetaryOrientation.hasSurfaceMap(objectID: entry.objectID),
                "\(entry.objectID) has a map but no rotation elements"
            )
            XCTAssertNotNil(PlanetSurfaceMaps.slice(objectID: entry.objectID))
        }
        XCTAssertEqual(PlanetSurfaceMaps.slice(objectID: "mars"), 0)
        XCTAssertEqual(PlanetSurfaceMaps.slice(objectID: "jupiter"), 1)
        XCTAssertEqual(PlanetSurfaceMaps.slice(objectID: "moon"), 2)
        XCTAssertNil(PlanetSurfaceMaps.slice(objectID: "venus"))
        XCTAssertEqual(PlanetSurfaceMaps.sliceParameter(objectID: "venus"), -1)
        XCTAssertEqual(PlanetSurfaceMaps.sliceParameter(objectID: "mars"), 0)
    }

    // MARK: - Ranges

    func testTheSubEarthPointIsAlwaysOnTheBody() {
        for id in ["mars", "jupiter", "moon"] {
            for step in stride(from: 0.0, through: 400.0, by: 3.7) {
                let orientation = PlanetaryOrientation.orientation(
                    objectID: id,
                    equatorial: EquatorialCoordinate(
                        rightAscensionDegrees: (step * 3).truncatingRemainder(dividingBy: 360),
                        declinationDegrees: 20 * sin(step * 0.1)
                    ),
                    julianDay: referenceJD + step
                )
                let o = try? XCTUnwrap(orientation)
                guard let o else { continue }
                XCTAssertGreaterThanOrEqual(o.subEarthLongitudeDegrees, 0.0, id)
                XCTAssertLessThan(o.subEarthLongitudeDegrees, 360.0, id)
                XCTAssertGreaterThanOrEqual(o.subEarthLatitudeDegrees, -90.0, id)
                XCTAssertLessThanOrEqual(o.subEarthLatitudeDegrees, 90.0, id)
                XCTAssertEqual(simd_length(o.poleDirection), 1.0, accuracy: 1e-9, id)
            }
        }
    }

    // MARK: - Rotation

    func testMarsRotatesOnceInASolDayNotAnEarthDay() {
        // Mars's rotation is 350.891982 deg/day, so it comes back to the same
        // sub-Earth longitude 360/350.891982 = 1.02595 days later. Holding the
        // direction to Mars fixed isolates the rotation from the orbit.
        let period = 360.0 / 350.891982443297
        let a = try! XCTUnwrap(marsAt(referenceJD))
        let b = try! XCTUnwrap(marsAt(referenceJD + period))
        XCTAssertEqual(
            angularDifference(a.subEarthLongitudeDegrees, b.subEarthLongitudeDegrees),
            0.0, accuracy: 0.05,
            "Mars did not return to the same face after one sidereal rotation"
        )

        // And half a rotation later it is showing the opposite side.
        let half = try! XCTUnwrap(marsAt(referenceJD + period / 2))
        XCTAssertEqual(
            abs(angularDifference(a.subEarthLongitudeDegrees, half.subEarthLongitudeDegrees)),
            180.0, accuracy: 0.1
        )
    }

    func testMarsRotationIsPrograde() {
        // A prograde rotator's sub-Earth *east* longitude decreases with time,
        // because the prime meridian is turning eastward past the sub-Earth
        // point. Getting this backwards would run the map the wrong way.
        let a = try! XCTUnwrap(marsAt(referenceJD))
        let b = try! XCTUnwrap(marsAt(referenceJD + 0.01))
        let change = angularDifference(b.subEarthLongitudeDegrees, a.subEarthLongitudeDegrees)
        XCTAssertLessThan(change, 0.0, "Mars's sub-Earth east longitude should decrease")
        // 350.89 deg/day * 0.01 day = 3.509 deg.
        XCTAssertEqual(change, -3.5089, accuracy: 0.01)
    }

    func testJupiterRotatesInJustUnderTenHours() {
        let period = 360.0 / 870.536
        XCTAssertEqual(period * 24.0, 9.925, accuracy: 0.005)
        let equatorial = EquatorialCoordinate(rightAscensionDegrees: 45, declinationDegrees: 15)
        let a = try! XCTUnwrap(PlanetaryOrientation.orientation(
            objectID: "jupiter", equatorial: equatorial, julianDay: referenceJD))
        let b = try! XCTUnwrap(PlanetaryOrientation.orientation(
            objectID: "jupiter", equatorial: equatorial, julianDay: referenceJD + period))
        XCTAssertEqual(
            angularDifference(a.subEarthLongitudeDegrees, b.subEarthLongitudeDegrees),
            0.0, accuracy: 0.05
        )
    }

    // MARK: - The Moon

    func testTheMoonKeepsTheSameFaceTurnedTowardEarth() {
        // The strongest available check on the whole construction. The Moon is
        // tidally locked, so if the geometry is right the sub-Earth longitude
        // must sit near zero for a real lunar trajectory — and it must do so
        // *without* anything in the code being told that the Moon is special.
        var maximumOffset = 0.0
        for day in stride(from: 0.0, through: 60.0, by: 0.25) {
            let jd = referenceJD + day
            let moon = MoonPosition.equatorialCoordinate(julianDay: jd)
            guard let orientation = PlanetaryOrientation.orientation(
                objectID: "moon", equatorial: moon, julianDay: jd
            ) else { continue }
            let offset = abs(angularDifference(orientation.subEarthLongitudeDegrees, 0.0))
            maximumOffset = max(maximumOffset, offset)
        }
        XCTAssertLessThan(
            maximumOffset, 12.0,
            "the Moon's sub-Earth longitude wandered \(maximumOffset) degrees — "
            + "libration in longitude is about +/- 8, so anything much larger "
            + "means the longitude construction is wrong"
        )
        XCTAssertGreaterThan(
            maximumOffset, 3.0,
            "the Moon showed almost no libration at all, which means the "
            + "sub-Earth point is not tracking the Moon's true direction"
        )
    }

    func testTheMoonLibratesInLatitudeToo() {
        var maximumLatitude = 0.0
        for day in stride(from: 0.0, through: 60.0, by: 0.25) {
            let jd = referenceJD + day
            let moon = MoonPosition.equatorialCoordinate(julianDay: jd)
            guard let orientation = PlanetaryOrientation.orientation(
                objectID: "moon", equatorial: moon, julianDay: jd
            ) else { continue }
            maximumLatitude = max(maximumLatitude, abs(orientation.subEarthLatitudeDegrees))
        }
        // Optical libration in latitude reaches about 6.7 degrees.
        XCTAssertGreaterThan(maximumLatitude, 3.0)
        XCTAssertLessThan(maximumLatitude, 12.0)
    }

    // MARK: - Pole direction

    func testMarsPoleIsRoughlyWhereItShouldBe() {
        let o = try! XCTUnwrap(marsAt(referenceJD))
        let pole = Precession.equatorial(fromVector: o.poleDirection)
        // IAU 2015 J2000 pole, precessed ~26 years to date, moves by well
        // under a degree. Mars's north pole lies in Cygnus, near Deneb.
        XCTAssertEqual(pole.rightAscensionDegrees, 317.6, accuracy: 1.5)
        XCTAssertEqual(pole.declinationDegrees, 54.4, accuracy: 1.5)
    }

    func testMarsAxialTiltShowsUpAsSubEarthLatitude() {
        // Mars's obliquity is 25.2 degrees, so over a full orbit the sub-Earth
        // latitude must range over roughly +/- 25 as the seasons turn. Sweeping
        // the *direction* to Mars around the ecliptic stands in for that.
        var minimum = 90.0, maximum = -90.0
        for longitude in stride(from: 0.0, to: 360.0, by: 2.0) {
            // A point on the ecliptic, converted to equatorial.
            let lambda = longitude * .pi / 180
            let epsilon = 23.4393 * .pi / 180
            let ra = atan2(cos(epsilon) * sin(lambda), cos(lambda)) * 180 / .pi
            let dec = asin(sin(epsilon) * sin(lambda)) * 180 / .pi
            guard let o = marsAt(referenceJD, ra: ra, dec: dec) else { continue }
            minimum = min(minimum, o.subEarthLatitudeDegrees)
            maximum = max(maximum, o.subEarthLatitudeDegrees)
        }
        XCTAssertGreaterThan(maximum, 20.0, "Mars's north pole never tips toward Earth")
        XCTAssertLessThan(minimum, -20.0, "Mars's south pole never tips toward Earth")
        XCTAssertLessThan(maximum, 32.0)
        XCTAssertGreaterThan(minimum, -32.0)
    }

    // MARK: - Continuity

    func testSubEarthLongitudeIsContinuousApartFromTheWrap() {
        // No jump other than the 0/360 seam, which the renderer handles by
        // wrapping the texture. A discontinuity anywhere else would show as
        // the map snapping mid-rotation.
        var previous: Double?
        for step in stride(from: 0.0, through: 3.0, by: 0.001) {
            guard let o = marsAt(referenceJD + step) else { continue }
            if let previous {
                let delta = abs(angularDifference(o.subEarthLongitudeDegrees, previous))
                XCTAssertLessThan(delta, 1.0, "longitude jumped at step \(step)")
            }
            previous = o.subEarthLongitudeDegrees
        }
    }

    func testTheTimeMachineFarFromNowStillProducesAValidOrientation() {
        // The prime-meridian angle accumulates hundreds of degrees a day, so a
        // century out it has wrapped ~13 million times. `normalizedDegrees`
        // has to keep that honest.
        for jd in [2_415_020.0, 2_488_070.0, 2_378_497.0] {
            let o = try! XCTUnwrap(marsAt(jd), "no orientation at JD \(jd)")
            XCTAssertTrue(o.subEarthLongitudeDegrees.isFinite)
            XCTAssertGreaterThanOrEqual(o.subEarthLongitudeDegrees, 0)
            XCTAssertLessThan(o.subEarthLongitudeDegrees, 360)
        }
    }

    func testNormalizedDegreesWraps() {
        XCTAssertEqual(PlanetaryOrientation.normalizedDegrees(-10), 350, accuracy: 1e-9)
        XCTAssertEqual(PlanetaryOrientation.normalizedDegrees(370), 10, accuracy: 1e-9)
        XCTAssertEqual(PlanetaryOrientation.normalizedDegrees(0), 0, accuracy: 1e-9)
        XCTAssertEqual(PlanetaryOrientation.normalizedDegrees(-720.5), 359.5, accuracy: 1e-9)
    }

    /// Signed difference a - b, reduced to -180...180.
    private func angularDifference(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }
}

final class SurfaceDetailRampTests: XCTestCase {

    /// The ramp the surface maps ride in on. It is shared with the procedural
    /// features, so these also protect the existing bands and rings.
    func testDetailIsZeroAtWideFieldAndFullWhenTheDiskIsLarge() {
        XCTAssertEqual(StarAppearance.detailLevel(pointSize: 4), 0.0, accuracy: 1e-9)
        XCTAssertEqual(StarAppearance.detailLevel(pointSize: 16), 0.0, accuracy: 1e-9)
        XCTAssertEqual(StarAppearance.detailLevel(pointSize: 52), 1.0, accuracy: 1e-9)
        XCTAssertEqual(StarAppearance.detailLevel(pointSize: 260), 1.0, accuracy: 1e-9)
    }

    func testDetailIsMonotoneAndContinuous() {
        // No popping: the map must not appear in a step as the user pinches.
        var previous = StarAppearance.detailLevel(pointSize: 0)
        var size: Float = 0.1
        while size <= 400 {
            let detail = StarAppearance.detailLevel(pointSize: size)
            XCTAssertGreaterThanOrEqual(detail, previous - 1e-6, "detail fell at \(size)")
            XCTAssertLessThan(abs(detail - previous), 0.02, "detail jumped at \(size)")
            XCTAssertGreaterThanOrEqual(detail, 0)
            XCTAssertLessThanOrEqual(detail, 1)
            previous = detail
            size += 0.1
        }
    }

    func testTheRampIsFlatAtBothEndsSoThereIsNoKink() {
        // Smoothstep has zero derivative at both ends, which is what makes the
        // start and finish of the fade invisible.
        let start: Float = 16, full: Float = 52
        let justInside = StarAppearance.detailLevel(pointSize: start + 0.5)
        let justBelowFull = StarAppearance.detailLevel(pointSize: full - 0.5)
        XCTAssertLessThan(justInside, 0.005, "the fade starts too abruptly")
        XCTAssertGreaterThan(justBelowFull, 0.995, "the fade finishes too abruptly")
    }

    func testAWideFieldPlanetIsStillAPlainTintedDot() {
        // At a 60-degree field on a 1600-point viewport, Mars is a marker, and
        // a marker must carry no surface map at all.
        let size = StarAppearance.solarSystemPointSize(
            objectID: "mars", kind: .planet, magnitude: 0.5,
            distanceKilometres: 1.5e8, fieldOfViewDegrees: 60, viewportWidth: 1600
        )
        XCTAssertEqual(StarAppearance.detailLevel(pointSize: size), 0.0, accuracy: 1e-9)
    }

    func testMarsAtOppositionFullyResolvesAtTheTightestField() {
        // The reason `Camera.minFieldOfView` had to come down from 3 degrees.
        // Mars at opposition is 25 arcseconds across; at the *old* limit it was
        // three and a half points and could never have shown a map at all.
        let atOldLimit = StarAppearance.solarSystemPointSize(
            objectID: "mars", kind: .planet, magnitude: -2.9,
            distanceKilometres: 6.0e7, fieldOfViewDegrees: 3.0, viewportWidth: 1600
        )
        XCTAssertEqual(StarAppearance.detailLevel(pointSize: atOldLimit), 0.0, accuracy: 1e-9)

        let atNewLimit = StarAppearance.solarSystemPointSize(
            objectID: "mars", kind: .planet, magnitude: -2.9,
            distanceKilometres: 6.0e7,
            fieldOfViewDegrees: Camera.minFieldOfView, viewportWidth: 1600
        )
        XCTAssertGreaterThan(atNewLimit, 52)
        XCTAssertEqual(StarAppearance.detailLevel(pointSize: atNewLimit), 1.0, accuracy: 1e-9)
    }

    func testJupiterAndSaturnAlsoResolveAtTheTightestField() {
        for (id, radiusDistance) in [("jupiter", 5.9e8), ("saturn", 1.2e9)] {
            let size = StarAppearance.solarSystemPointSize(
                objectID: id, kind: .planet, magnitude: -2.5,
                distanceKilometres: radiusDistance,
                fieldOfViewDegrees: Camera.minFieldOfView, viewportWidth: 1600
            )
            XCTAssertEqual(
                StarAppearance.detailLevel(pointSize: size), 1.0, accuracy: 1e-9,
                "\(id) still cannot resolve at the tightest field"
            )
        }
    }

    func testTheZoomLimitIsTightEnoughToBeWorthHaving() {
        XCTAssertLessThanOrEqual(
            Camera.minFieldOfView, 0.25,
            "the zoom limit has been raised back to where planets cannot resolve"
        )
        XCTAssertGreaterThan(Camera.minFieldOfView, 0.0)
        XCTAssertLessThan(Camera.minFieldOfView, Camera.maxFieldOfView)
    }
}
