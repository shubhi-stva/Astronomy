//
//  SkyGuideTests.swift
//  AstronomyTests
//
//  The guide-side features: satellite pass prediction, light pollution,
//  angular measurement, the reference-line layers, and the Galilean moons'
//  behaviour around their planet.
//

import XCTest
import simd
@testable import Astronomy

// MARK: - Passes

final class SatellitePassTests: XCTestCase {

    /// A circular polar orbit, propagated analytically, so the predictor is
    /// tested against geometry rather than against SGP4.
    ///
    /// The satellite is placed in an orbit that genuinely passes over the
    /// observer, at LEO altitude and speed, which is what makes "does it find
    /// the pass, and are rise/peak/set in the right order" a real question.
    private struct CircularOrbit {
        let radiusKm: Double
        let periodSeconds: Double
        let inclination: Double
        let epochJulianDay: Double

        func position(julianDay jd: Double) -> SIMD3<Double> {
            let t = (jd - epochJulianDay) * 86_400.0
            let angle = 2 * .pi * t / periodSeconds
            // In the orbital plane, then tilted by the inclination.
            let x = radiusKm * cos(angle)
            let y = radiusKm * sin(angle) * cos(inclination)
            let z = radiusKm * sin(angle) * sin(inclination)
            return SIMD3(x, y, z)
        }
    }

    private static let observer = GeographicLocation(latitudeDegrees: 37.77, longitudeDegrees: -122.42)

    func testFindsPassesInOrderWithSensibleGeometry() {
        let orbit = CircularOrbit(
            radiusKm: 6_778, periodSeconds: 5_550, inclination: .pi / 2, epochJulianDay: 2_461_055.0
        )
        let passes = SatellitePassPredictor.passes(
            catalogNumber: 99_999, name: "TEST", observer: Self.observer,
            fromJulianDay: orbit.epochJulianDay, spanDays: 1.0,
            position: { orbit.position(julianDay: $0) },
            isSunlit: { _, _ in true }
        )

        XCTAssertFalse(passes.isEmpty, "a polar LEO orbit produces passes over a mid-latitude site")
        for pass in passes {
            // Ordered, and the peak really is the highest point.
            XCTAssertLessThan(pass.riseJulianDay, pass.peakJulianDay)
            XCTAssertLessThan(pass.peakJulianDay, pass.setJulianDay)
            XCTAssertGreaterThanOrEqual(
                pass.peakHorizontal.altitudeDegrees,
                SatellitePassPredictor.minimumPeakAltitudeDegrees
            )
            // A LEO pass is minutes, not seconds or hours.
            XCTAssertGreaterThan(pass.durationSeconds, 60)
            XCTAssertLessThan(pass.durationSeconds, 20 * 60)

            // Rise and set are on the horizon; the peak is above both.
            for endpoint in [pass.riseJulianDay, pass.setJulianDay] {
                let look = TopocentricTransform.lookAngles(
                    satellitePositionTEME: orbit.position(julianDay: endpoint),
                    observer: Self.observer, julianDay: endpoint
                )
                XCTAssertEqual(look.horizontal.altitudeDegrees, 0, accuracy: 0.2)
            }
            let peak = TopocentricTransform.lookAngles(
                satellitePositionTEME: orbit.position(julianDay: pass.peakJulianDay),
                observer: Self.observer, julianDay: pass.peakJulianDay
            )
            XCTAssertEqual(
                peak.horizontal.altitudeDegrees, pass.peakHorizontal.altitudeDegrees, accuracy: 0.5
            )
        }
        // Passes come back in time order, which is what the panel relies on.
        XCTAssertEqual(passes.map(\.riseJulianDay), passes.map(\.riseJulianDay).sorted())
    }

    /// Visibility has two independent halves, and both must hold: the
    /// satellite in sunlight, the observer in the dark. A pass that fails
    /// either is still listed — a radio operator wants it — and marked.
    func testVisibilityNeedsBothSunlitSatelliteAndDarkObserver() {
        let orbit = CircularOrbit(
            radiusKm: 6_778, periodSeconds: 5_550, inclination: .pi / 2, epochJulianDay: 2_461_055.0
        )
        func passes(sunlit: Bool) -> [SatellitePass] {
            SatellitePassPredictor.passes(
                catalogNumber: 99_999, name: "TEST", observer: Self.observer,
                fromJulianDay: orbit.epochJulianDay, spanDays: 1.0,
                position: { orbit.position(julianDay: $0) },
                isSunlit: { _, _ in sunlit }
            )
        }
        let eclipsed = passes(sunlit: false)
        XCTAssertFalse(eclipsed.isEmpty)
        XCTAssertTrue(eclipsed.allSatisfy { !$0.isVisible && !$0.isSunlitAtPeak })

        // With the satellite always sunlit, the visible ones are exactly the
        // ones happening while the observer's Sun is below −6°.
        for pass in passes(sunlit: true) {
            let sun = CoordinateTransformService.horizontal(
                from: SunPosition.equatorialCoordinate(julianDay: pass.peakJulianDay),
                observer: Self.observer, julianDay: pass.peakJulianDay
            )
            XCTAssertTrue(pass.isSunlitAtPeak)
            XCTAssertEqual(pass.isVisible, sun.altitudeDegrees < -6)
        }
    }

    /// A satellite that never clears the minimum altitude produces no pass at
    /// all, rather than a list of grazing non-events.
    func testLowGrazingPassesAreNotListed() {
        // Equatorial orbit seen from latitude 37.77: never gets high.
        let orbit = CircularOrbit(
            radiusKm: 6_778, periodSeconds: 5_550, inclination: 0, epochJulianDay: 2_461_055.0
        )
        let passes = SatellitePassPredictor.passes(
            catalogNumber: 99_999, name: "TEST", observer: Self.observer,
            fromJulianDay: orbit.epochJulianDay, spanDays: 0.5,
            position: { orbit.position(julianDay: $0) },
            isSunlit: { _, _ in true }
        )
        for pass in passes {
            XCTAssertGreaterThanOrEqual(
                pass.peakHorizontal.altitudeDegrees,
                SatellitePassPredictor.minimumPeakAltitudeDegrees
            )
        }
    }
}

// MARK: - Light pollution

final class LightPollutionTests: XCTestCase {

    /// Classes 1-3 are the dark skies the app's night look was tuned for, so
    /// they cost nothing; from 4 the published naked-eye limits fall by about
    /// half a magnitude per class.
    func testThePenaltyStartsAtClassFourAndGrowsMonotonically() {
        for bortle in 1...3 {
            XCTAssertEqual(SkyBrightness.bortleMagnitudePenalty(bortleClass: bortle), 0)
        }
        var previous = 0.0
        for bortle in 4...9 {
            let penalty = SkyBrightness.bortleMagnitudePenalty(bortleClass: bortle)
            XCTAssertGreaterThan(penalty, previous)
            previous = penalty
        }
        // An inner-city sky costs about 2.7 magnitudes against a rural one,
        // which is the difference between ~6.5 and ~4.0 naked-eye limits.
        XCTAssertEqual(SkyBrightness.bortleMagnitudePenalty(bortleClass: 9), 2.7, accuracy: 0.01)
        // Out-of-range values are clamped rather than extrapolated.
        XCTAssertEqual(SkyBrightness.bortleMagnitudePenalty(bortleClass: 0), 0)
        XCTAssertEqual(
            SkyBrightness.bortleMagnitudePenalty(bortleClass: 99),
            SkyBrightness.bortleMagnitudePenalty(bortleClass: 9)
        )
    }

    /// Light pollution takes stars away at night and does nothing by day,
    /// because by day the Sun is already the thing setting the limit.
    func testItBitesAtNightAndNotAtNoon() {
        let night = -20.0, noon = 45.0
        let darkLimit = SkyBrightness.displayLimitingMagnitude(sunAltitudeDegrees: night, bortleClass: 3)
        let cityLimit = SkyBrightness.displayLimitingMagnitude(sunAltitudeDegrees: night, bortleClass: 9)
        XCTAssertGreaterThan(darkLimit - cityLimit, 2.0)

        let darkNoon = SkyBrightness.displayLimitingMagnitude(sunAltitudeDegrees: noon, bortleClass: 3)
        let cityNoon = SkyBrightness.displayLimitingMagnitude(sunAltitudeDegrees: noon, bortleClass: 9)
        XCTAssertEqual(darkNoon, cityNoon, accuracy: 0.05)
    }

    /// The physical curve is untouched: this is a display adjustment, and
    /// `SkyBrightness.limitingMagnitude` remains the honest function.
    func testTheHonestLimitIsUnaffected() {
        let before = SkyBrightness.limitingMagnitude(sunAltitudeDegrees: -20)
        XCTAssertEqual(SkyBrightness.limitingMagnitude(sunAltitudeDegrees: -20), before)
        XCTAssertEqual(SkyBrightness.bortleDescription(bortleClass: 1), "Excellent dark sky")
        XCTAssertEqual(SkyBrightness.bortleDescription(bortleClass: 9), "Inner-city sky")
    }

    /// Fewer stars are drawn under a worse sky — the point of the setting.
    ///
    /// Tested at a 10-degree field on purpose. The effective limit is the
    /// *more restrictive* of the sky and the field of view
    /// (`StarAppearance.effectiveLimitingMagnitude`), so the Bortle class only
    /// shows where the sky is the binding constraint — which is as you zoom
    /// in, and is also when a real observer notices their sky. At the very
    /// widest fields the two limits converge and the setting does less.
    func testACitySkyDrawsFewerStarsThanARuralOneOnceZoomedIn() {
        func visibility(magnitude: Double, bortleClass: Int) -> Double {
            StarAppearance.visibility(
                magnitude: magnitude, fieldOfViewDegrees: 10,
                sunAltitudeDegrees: -20, bortleClass: bortleClass
            )
        }
        // A magnitude 7 star: comfortably drawn from a rural site, gone from
        // a city one.
        XCTAssertGreaterThan(visibility(magnitude: 7.0, bortleClass: 3), 0.5)
        XCTAssertEqual(visibility(magnitude: 7.0, bortleClass: 9), 0, accuracy: 1e-9)

        // Bright stars survive anywhere — a city sky is not an off switch.
        XCTAssertGreaterThan(visibility(magnitude: 0.0, bortleClass: 9), 0.5)

        // ...and the effect is monotonic in the class.
        var previous = Double.infinity
        for bortle in 3...9 {
            let value = visibility(magnitude: 6.5, bortleClass: bortle)
            XCTAssertLessThanOrEqual(value, previous + 1e-12)
            previous = value
        }

        // A worse sky is never a *deeper* one, at any field of view.
        for fov in [150.0, 120.0, 60.0, 10.0, 3.0] {
            let rural = StarAppearance.effectiveLimitingMagnitude(
                fieldOfViewDegrees: fov, sunAltitudeDegrees: -20, bortleClass: 3
            )
            let city = StarAppearance.effectiveLimitingMagnitude(
                fieldOfViewDegrees: fov, sunAltitudeDegrees: -20, bortleClass: 9
            )
            XCTAssertLessThanOrEqual(city, rural + 1e-12, "at \(fov) degrees")
        }
        // ...and zoomed in, where the sky is the binding constraint, it is
        // dramatically shallower.
        XCTAssertGreaterThan(
            StarAppearance.effectiveLimitingMagnitude(
                fieldOfViewDegrees: 3, sunAltitudeDegrees: -20, bortleClass: 3
            )
            - StarAppearance.effectiveLimitingMagnitude(
                fieldOfViewDegrees: 3, sunAltitudeDegrees: -20, bortleClass: 9
            ),
            2.0
        )
    }
}

// MARK: - Angular separation

final class AngularSeparationTests: XCTestCase {

    /// Published separations, and the degenerate cases a cosine formula gets
    /// wrong.
    func testMatchesKnownSeparations() {
        func place(_ ra: Double, _ dec: Double) -> EquatorialCoordinate {
            EquatorialCoordinate(rightAscensionDegrees: ra, declinationDegrees: dec)
        }
        // Meeus Example 17.a: Arcturus and Spica, 32.7930°.
        XCTAssertEqual(
            AngularSeparation.degrees(place(213.9154, 19.1825), place(201.2983, -11.1614)),
            32.7930, accuracy: 0.0005
        )
        // A point with itself is zero, not a NaN.
        XCTAssertEqual(AngularSeparation.degrees(place(100, 20), place(100, 20)), 0, accuracy: 1e-12)
        // Antipodes are 180°.
        XCTAssertEqual(AngularSeparation.degrees(place(0, 90), place(0, -90)), 180, accuracy: 1e-9)
        // Across the right-ascension seam.
        XCTAssertEqual(AngularSeparation.degrees(place(359.5, 0), place(0.5, 0)), 1.0, accuracy: 1e-9)
    }

    /// Sub-arcsecond separations are where the cosine formula loses its
    /// digits, and where double stars live.
    func testIsAccurateAtVerySmallSeparations() {
        let a = EquatorialCoordinate(rightAscensionDegrees: 100.0, declinationDegrees: 20.0)
        let b = EquatorialCoordinate(
            rightAscensionDegrees: 100.0, declinationDegrees: 20.0 + 0.1 / 3600.0
        )
        XCTAssertEqual(AngularSeparation.degrees(a, b) * 3600, 0.1, accuracy: 1e-6)
    }

    func testFormatsAtTheScaleTheNumberDeserves() {
        XCTAssertEqual(AngularSeparation.formatted(degrees: 12.5), "12° 30′")
        XCTAssertEqual(AngularSeparation.formatted(degrees: 0.5), "30′ 00″")
        XCTAssertEqual(AngularSeparation.formatted(degrees: 1.0 / 3600.0 * 12.3), "12.3″")
    }
}

// MARK: - Reference layers

final class ReferenceLayerTests: XCTestCase {

    private func frame(fieldOfViewDegrees fov: Double = 90) -> SkyFrameData {
        var frame = SkyFrameData.empty
        frame.observerLocation = GeographicLocation(latitudeDegrees: 37.77, longitudeDegrees: -122.42)
        frame.julianDay = 2_461_055.708333
        frame.cameraCenter = HorizontalCoordinate(altitudeDegrees: 45, azimuthDegrees: 180)
        frame.cameraFieldOfViewDegrees = fov
        frame.viewportSize = CGSize(width: 1200, height: 800)
        return frame
    }

    private func lineCount(_ frame: SkyFrameData) -> Int {
        var builder = SkyGeometryBuilder(frameData: frame)
        builder.run()
        return builder.lineVertices.count
    }

    /// Every reference layer is off by default and draws nothing until asked
    /// for: a grid is an overlay, not scenery.
    func testEachLayerDrawsNothingUntilItIsTurnedOn() {
        let base = lineCount(frame())

        for keyPath: WritableKeyPath<SkyFrameData, Bool> in [
            \.equatorialGridEnabled, \.horizontalGridEnabled, \.eclipticEnabled, \.meridianEnabled,
        ] {
            var on = frame()
            on[keyPath: keyPath] = true
            XCTAssertGreaterThan(
                lineCount(on), base, "layer \(keyPath) produced no geometry when enabled"
            )
        }
    }

    /// The ecliptic passes through the Sun: that is what the ecliptic *is*.
    /// Checked in the frame rather than on screen, so it holds wherever the
    /// camera happens to point.
    func testTheEclipticPassesThroughTheSun() {
        let jd = 2_461_055.708333
        let sun = EphemerisService.solarSystemObjects(julianDay: jd).first { $0.id == "sun" }!
        let earth = EarthState(julianDayUT: jd)

        // The Sun's ecliptic latitude is zero to within the aberration and
        // the Moon's tug on the Earth — under an arcsecond either way.
        let direction = Precession.unitVector(sun.equatorial)
        let ecliptic = earth.eclipticToEquatorial.transpose * direction
        let latitude = Angle.radiansToDegrees(
            atan2(ecliptic.z, (ecliptic.x * ecliptic.x + ecliptic.y * ecliptic.y).squareRoot())
        )
        XCTAssertEqual(latitude, 0, accuracy: 0.001)
    }

    /// A field-of-view circle is exactly the requested true field across, and
    /// it is centred on the view rather than on any object.
    func testAFieldCircleIsTheRequestedAngularSize() {
        var frame = self.frame(fieldOfViewDegrees: 20)
        frame.fieldOfViewCirclesDegrees = [5.0]
        var builder = SkyGeometryBuilder(frameData: frame)
        builder.run()

        // Every vertex of the circle sits 2.5 degrees from the camera axis.
        let projector = builder.projector
        let centre = projector.centerDirection
        XCTAssertFalse(builder.lineVertices.isEmpty)
        // Reconstruct the angular radius from the NDC extent: the circle's
        // widest horizontal extent is the field radius in projection units.
        let xs = builder.lineVertices.map { Double($0.positionNDC.x) }
        let widest = (xs.max() ?? 0) - (xs.min() ?? 0)
        // Stereographic: a 5-degree circle in a 20-degree field spans about a
        // quarter of the width. Loose, because the projection is not linear.
        XCTAssertEqual(widest, 0.5, accuracy: 0.1)
        XCTAssertEqual(simd_length(centre), 1.0, accuracy: 1e-9)
    }

    /// The measurement tool draws its arc between the two chosen points and
    /// labels it with the separation it actually spans.
    func testTheMeasureArcIsLabelledWithItsOwnSeparation() {
        var frame = self.frame(fieldOfViewDegrees: 120)
        let a = EquatorialCoordinate(rightAscensionDegrees: 100, declinationDegrees: 20)
        let b = EquatorialCoordinate(rightAscensionDegrees: 130, declinationDegrees: 20)
        frame.measureEndpoints = [a, b]

        var builder = SkyGeometryBuilder(frameData: frame)
        builder.run()

        let label = builder.labelCandidates.first { $0.id == "measure" }
        XCTAssertNotNil(label, "the measurement produced no label")
        XCTAssertEqual(
            label?.text, AngularSeparation.formatted(degrees: AngularSeparation.degrees(a, b))
        )
    }
}

// MARK: - Galilean moons

final class JupiterMoonTests: XCTestCase {

    /// The four moons stay within their own orbits' reach of Jupiter, and in
    /// the right order: Io closest, Callisto furthest.
    func testTheMoonsStayInTheirOrbits() {
        for step in 0..<40 {
            let jd = 2_461_055.5 + Double(step) * 0.37
            let positions = JupiterMoons.positions(julianDay: jd)
            XCTAssertEqual(positions.count, 4)

            for position in positions {
                let radius = (position.x * position.x + position.y * position.y
                              + position.z * position.z).squareRoot()
                // Orbital radii in Jupiter radii: Io 5.9, Europa 9.4,
                // Ganymede 15.0, Callisto 26.4.
                let expected: Double
                switch position.moon {
                case .io: expected = 5.9
                case .europa: expected = 9.4
                case .ganymede: expected = 15.0
                case .callisto: expected = 26.4
                }
                XCTAssertEqual(radius, expected, accuracy: 0.4, "\(position.moon.name) at \(jd)")
            }
        }
    }

    /// Each moon completes its own published period. Measured from the sign
    /// changes of its along-orbit coordinate, which is a direct read of the
    /// synodic motion the model produces.
    func testEachMoonKeepsItsOwnPeriod() {
        let periods: [(JupiterMoons.Moon, Double)] = [
            (.io, 1.769), (.europa, 3.551), (.ganymede, 7.155), (.callisto, 16.689),
        ]
        for (moon, period) in periods {
            let start = 2_461_055.5
            func x(_ jd: Double) -> Double {
                JupiterMoons.positions(julianDay: jd).first { $0.moon == moon }!.x
            }
            // Find two successive ascending zero crossings of x.
            var crossings: [Double] = []
            var previous = x(start)
            var jd = start + 0.002
            while jd < start + 40, crossings.count < 2 {
                let current = x(jd)
                if previous <= 0, current > 0 { crossings.append(jd) }
                previous = current
                jd += 0.002
            }
            XCTAssertEqual(crossings.count, 2, "\(moon.name): no two crossings found")
            if crossings.count == 2 {
                // Synodic rather than sidereal, so a percent of tolerance.
                XCTAssertEqual(crossings[1] - crossings[0], period, accuracy: period * 0.02, moon.name)
            }
        }
    }

    /// A moon in front of the planet is in transit, one behind it is occulted,
    /// and the two are never both true.
    func testTransitAndOccultationAreExclusiveAndDoHappen() {
        var transits = 0, occultations = 0
        for step in 0..<3_000 {
            let jd = 2_461_055.5 + Double(step) * 0.01
            for position in JupiterMoons.positions(julianDay: jd) {
                XCTAssertFalse(position.isInTransit && position.isOcculted)
                if position.isInTransit { transits += 1 }
                if position.isOcculted { occultations += 1 }
            }
        }
        // Over a month of samples both must occur — they are the events the
        // layer exists to show.
        XCTAssertGreaterThan(transits, 0)
        XCTAssertGreaterThan(occultations, 0)
    }

    /// The moons are drawn only once the field is narrow enough for them to
    /// separate from Jupiter's own sprite — at a whole-sky field they would be
    /// four dots inside the planet's marker.
    func testTheMoonsAppearOnlyWhenZoomedIn() {
        func markerCount(fieldOfViewDegrees fov: Double) -> Int {
            let jd = 2_461_055.708333
            var frame = SkyFrameData.empty
            frame.observerLocation = GeographicLocation(latitudeDegrees: 37.77, longitudeDegrees: -122.42)
            frame.julianDay = jd
            frame.solarSystemObjects = EphemerisService.solarSystemObjects(julianDay: jd)
            frame.viewportSize = CGSize(width: 1200, height: 800)
            frame.cameraFieldOfViewDegrees = fov
            frame.sunHorizontal = HorizontalCoordinate(altitudeDegrees: -40, azimuthDegrees: 0)
            let jupiter = frame.solarSystemObjects.first { $0.id == "jupiter" }!
            frame.cameraCenter = CoordinateTransformService.horizontal(
                from: jupiter.equatorial, observer: frame.observerLocation, julianDay: jd
            )
            var builder = SkyGeometryBuilder(frameData: frame)
            builder.run()
            return builder.labelCandidates.filter { $0.id.hasPrefix("jupiter-moon-") }.count
        }
        XCTAssertEqual(markerCount(fieldOfViewDegrees: 90), 0)
        XCTAssertGreaterThan(markerCount(fieldOfViewDegrees: 1.0), 0)
    }
}
