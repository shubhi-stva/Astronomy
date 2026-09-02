//
//  SatelliteSubTickTests.swift
//  AstronomyTests
//
//  The satellite layer draws at the display's rate from a propagation that
//  runs at 2.5 Hz, so *something* has to fill in between ticks. These tests
//  pin what that something is allowed to cost in pixels — and they exist
//  because at the camera's current 0.15-degree zoom limit the old answer
//  (`r + v·dt`) had started to cost several of them, which reads as satellites
//  jumping.
//
//  Everything here is synchronous and the classes are deliberately not
//  `@MainActor`; see the note at the top of `RenderPerformanceTests`.
//

import XCTest
import simd
@testable import Astronomy

/// These tests exist as much for the numbers they measure as for the
/// assertions they make, and `xcodebuild` forwards neither the test host's
/// stdout nor its stderr into its log. So every measurement is also filed as an
/// attachment on the result bundle, the same way `RenderPerformanceTests` does
/// it. Retrieve them with
///
///     xcrun xcresulttool export attachments --path <bundle> --output-path <dir>
///
extension XCTestCase {
    func report(_ message: String) {
        print(message)
        fputs(message + "\n", stderr)
        fflush(stderr)
        let attachment = XCTAttachment(string: message)
        attachment.name = "measurement-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

// MARK: - The scheme, in isolation

final class SatelliteSubTickInterpolationTests: XCTestCase {

    /// The interpolation has to reproduce *both* endpoints exactly. The second
    /// one is the whole point: the drawn position at the end of a tick is the
    /// position the next snapshot will assert, so there is no correction left
    /// to make and therefore no step to see.
    func testInterpolationReproducesBothEndpointsExactly() {
        let h = SatelliteTracker.tickInterval
        let r0 = SIMD3(6_800.0, 120.0, -400.0)
        let v0 = SIMD3(1.2, 7.3, 0.9)
        let r1 = SIMD3(6_800.5, 123.0, -399.6)
        let v1 = SIMD3(1.19, 7.31, 0.88)

        let atStart = SatelliteSubTick.position(
            start: r0, startVelocity: v0, end: r1, endVelocity: v1, interval: h, elapsed: 0
        )
        let atEnd = SatelliteSubTick.position(
            start: r0, startVelocity: v0, end: r1, endVelocity: v1, interval: h, elapsed: h
        )
        XCTAssertLessThan(simd_distance(atStart, r0), 1e-12)
        XCTAssertLessThan(simd_distance(atEnd, r1), 1e-12)
    }

    /// Past the end of the interval it must continue in a straight line from
    /// the *end* state rather than letting the cubic run away — a tick that
    /// arrives late has to degrade to the old behaviour, not to nonsense.
    func testBeyondTheIntervalItContinuesLinearlyAndStaysContinuous() {
        let h = SatelliteTracker.tickInterval
        let r0 = SIMD3(6_800.0, 120.0, -400.0)
        let v0 = SIMD3(1.2, 7.3, 0.9)
        let r1 = SIMD3(6_800.5, 123.0, -399.6)
        let v1 = SIMD3(1.19, 7.31, 0.88)

        func at(_ t: Double) -> SIMD3<Double> {
            SatelliteSubTick.position(
                start: r0, startVelocity: v0, end: r1, endVelocity: v1, interval: h, elapsed: t
            )
        }
        XCTAssertLessThan(simd_distance(at(h + 1.0), r1 + v1), 1e-12)
        XCTAssertLessThan(simd_distance(at(-1.0), r0 - v0), 1e-12)
        // No seam at either join: stepping across h changes the position by
        // about one frame's worth of motion and nothing more.
        let epsilon = 1e-4
        XCTAssertLessThan(simd_distance(at(h - epsilon), at(h + epsilon)), 2 * epsilon * 8.0)
        XCTAssertLessThan(simd_distance(at(-epsilon), at(epsilon)), 2 * epsilon * 8.0)
    }

    /// The blend has to be off at ordinary fields (so nothing changes for the
    /// wide case at all), on when zoomed in, and continuous in between so that
    /// crossing the threshold is not itself a jump.
    func testTheBlendIsOffWideOnNarrowAndContinuousBetween() {
        XCTAssertEqual(SatelliteSubTick.interpolationWeight(fieldOfViewDegrees: 150), 0)
        XCTAssertEqual(SatelliteSubTick.interpolationWeight(fieldOfViewDegrees: 90), 0)
        XCTAssertEqual(SatelliteSubTick.interpolationWeight(fieldOfViewDegrees: 45), 0)
        XCTAssertEqual(
            SatelliteSubTick.interpolationWeight(
                fieldOfViewDegrees: SatelliteSubTick.linearOnlyFieldOfViewDegrees
            ), 0
        )
        XCTAssertEqual(SatelliteSubTick.interpolationWeight(fieldOfViewDegrees: 0.15), 1)
        XCTAssertEqual(
            SatelliteSubTick.interpolationWeight(
                fieldOfViewDegrees: SatelliteSubTick.fullyInterpolatedFieldOfViewDegrees
            ), 1
        )

        var previous = 0.0
        var fov = SatelliteSubTick.linearOnlyFieldOfViewDegrees
        while fov > SatelliteSubTick.fullyInterpolatedFieldOfViewDegrees {
            let weight = SatelliteSubTick.interpolationWeight(fieldOfViewDegrees: fov)
            XCTAssertGreaterThanOrEqual(weight, previous, "weight went backwards at \(fov)")
            XCTAssertLessThan(weight - previous, 0.05, "weight stepped at \(fov)")
            previous = weight
            fov -= 0.01
        }

        // And the tracker only spends the second propagation where the weight
        // is actually non-zero — no tick computes states that get multiplied
        // by nothing.
        XCTAssertFalse(SatelliteSubTick.isWorthComputing(fieldOfViewDegrees: 90))
        XCTAssertFalse(
            SatelliteSubTick.isWorthComputing(
                fieldOfViewDegrees: SatelliteSubTick.linearOnlyFieldOfViewDegrees
            )
        )
        XCTAssertTrue(SatelliteSubTick.isWorthComputing(fieldOfViewDegrees: 0.15))
    }

    /// Against real SGP4, over the standard verification set, the residual at a
    /// tick boundary must be *zero* — not small, zero — because the
    /// interpolation lands on the next snapshot's own state by construction.
    /// This is the property the whole fix rests on.
    func testAgainstRealOrbitsTheTickBoundaryResidualIsZero() throws {
        let h = SatelliteTracker.tickInterval
        var worstLinear = 0.0
        var worstInterpolated = 0.0
        var checked = 0

        for testCase in SGP4VerificationTests.sgp4VerificationCases {
            guard let tle = TwoLineElement.parse(
                name: nil, line1: testCase.line1, line2: testCase.line2
            ), var propagator = SGP4Propagator(tle: tle),
                  let baseMinutes = testCase.expected.first?.0,
                  let s0 = try? propagator.propagate(minutesSinceEpoch: baseMinutes),
                  let s1 = try? propagator.propagate(minutesSinceEpoch: baseMinutes + h / 60.0)
            else { continue }
            checked += 1

            // What the old scheme would have to correct when the next snapshot
            // lands, and what the new one has to correct.
            worstLinear = max(
                worstLinear, simd_distance(s0.position + s0.velocity * h, s1.position)
            )
            worstInterpolated = max(worstInterpolated, simd_distance(
                SatelliteSubTick.position(
                    start: s0.position, startVelocity: s0.velocity,
                    end: s1.position, endVelocity: s1.velocity, interval: h, elapsed: h
                ),
                s1.position
            ))
        }

        XCTAssertGreaterThan(checked, 5)
        // The regression this replaces: metres of uncorrected error, which the
        // 0.15-degree zoom limit turns into pixels.
        XCTAssertGreaterThan(worstLinear * 1000, 1.0)
        XCTAssertLessThan(worstInterpolated * 1000, 1e-6,
                          "interpolated tick-boundary residual is \(worstInterpolated * 1000) m")
        report(String(format: "tick-boundary residual over %d orbits: linear %.3f m, interpolated %.3e m",
                     checked, worstLinear * 1000, worstInterpolated * 1000))
    }
}

// MARK: - Through the real render pipeline

/// The regression that must not come back: at the camera's tightest field, the
/// drawn marker must not step when a fresh propagation tick lands.
///
/// This drives `SkyGeometryBuilder` frame by frame across a real tick boundary
/// with a real orbit, keeping the camera centred on the satellite's *true*
/// position so that the marker's NDC offset from screen centre is exactly the
/// positional error, in pixels, with nothing else mixed in.
final class SatelliteNarrowFieldSmoothnessTests: XCTestCase {

    private static let viewport = CGSize(width: 1512, height: 900)
    private static let observer = GeographicLocation(
        latitudeDegrees: 37.77, longitudeDegrees: -122.42
    )

    /// Real ISS elements, and the choice matters. The error this test is about
    /// is an error in *metres*, and what it costs in pixels is metres divided
    /// by slant range: the same few metres that vanish at a high-apogee object
    /// tens of thousands of kilometres away are several pixels on a low pass a
    /// few hundred kilometres overhead. A close LEO pass is therefore the worst
    /// case for visible jumping, and it is also the case a person is most
    /// likely to be watching.
    private static let line1 = "1 25544U 98067A   26229.54791667  .00016717  00000-0  10270-3 0  9007"
    private static let line2 = "2 25544  51.6416 247.4627 0006703 130.5360 325.0288 15.72125391563537"

    private struct Trace {
        /// Largest offset, in pixels, between the drawn marker and the truth.
        var worstErrorPixels = 0.0
        /// Largest single-frame *step* in that offset — the visible jump.
        var worstStepPixels = 0.0
        var frames = 0
    }

    /// Runs `frameCount` frames spanning one tick boundary and measures how far
    /// the drawn marker sits from the truth, and how much that moves per frame.
    private func trace(
        fieldOfViewDegrees fov: Double, subTick: Bool
    ) throws -> Trace {
        guard let tle = TwoLineElement.parse(name: "TEST", line1: Self.line1, line2: Self.line2),
              let satellite = Satellite(tle: tle) else {
            throw XCTSkip("element set did not parse")
        }
        let tick = SatelliteTracker.tickInterval
        let tickDays = tick / 86_400.0

        // Find the *closest* pass in a day: the highest the object gets in the
        // sky, which is where the slant range is smallest and therefore where
        // metres of positional error cost the most pixels.
        var baseJD = tle.epochJulianDay
        var bestAltitude = -90.0
        for step in 0..<8_640 {                       // one day at 10-second steps
            let jd = tle.epochJulianDay + Double(step) * (10.0 / 86_400.0)
            guard let state = satellite.propagate(julianDay: jd) else { continue }
            let look = TopocentricTransform.lookAngles(
                satellitePositionTEME: state.position, observer: Self.observer, julianDay: jd
            )
            if look.horizontal.altitudeDegrees > bestAltitude {
                bestAltitude = look.horizontal.altitudeDegrees
                baseJD = jd
            }
        }
        try XCTSkipUnless(bestAltitude > 60, "no close pass in the search window")

        // Two consecutive propagation ticks, each carrying the exact state at
        // the end of its own interval when the sub-tick pass is enabled — the
        // same shape `SatelliteTracker` produces.
        func snapshot(at jd: Double) throws -> SatelliteSnapshot {
            guard let state = satellite.propagate(julianDay: jd) else {
                throw XCTSkip("propagator refused the test instant")
            }
            let sample = SatelliteSample(
                index: 0,
                catalogNumber: Satellite.issCatalogNumber,   // notable: always drawn
                regime: satellite.regime,
                isNotable: true,
                epochJulianDay: satellite.epochJulianDay,
                position: state.position,
                velocity: state.velocity,
                illumination: .sunlit,
                altitudeDegreesAtSnapshot: 60
            )
            guard subTick, let end = satellite.propagate(julianDay: jd + tickDays) else {
                return SatelliteSnapshot(
                    julianDay: jd, samples: [sample], propagationDuration: 0, altitudeOrder: [0]
                )
            }
            return SatelliteSnapshot(
                julianDay: jd, samples: [sample], propagationDuration: 0, altitudeOrder: [0],
                subTickStates: [
                    SatelliteSubTickState(position: end.position, velocity: end.velocity)
                ],
                subTickIntervalSeconds: tick
            )
        }

        let first = try snapshot(at: baseJD)
        let second = try snapshot(at: baseJD + tickDays)

        let descriptors = [SatelliteDescriptor(
            catalogNumber: Satellite.issCatalogNumber, name: "TEST",
            regime: satellite.regime, internationalDesignator: "58-002B",
            epochJulianDay: satellite.epochJulianDay, isNotable: true
        )]

        // 120 Hz frames spanning the whole of the first tick and into the
        // second, so the boundary itself is crossed mid-trace.
        let frameSeconds = 1.0 / 120.0
        var result = Trace()
        var previousError: SIMD2<Double>?

        var elapsed = 0.0
        while elapsed <= tick * 1.5 {
            let jd = baseJD + elapsed / 86_400.0
            guard let truth = satellite.propagate(julianDay: jd) else { break }

            // Camera locked to the truth: the marker's offset from screen
            // centre then *is* the error.
            let look = TopocentricTransform.lookAngles(
                satellitePositionTEME: truth.position, observer: Self.observer, julianDay: jd
            )

            var frame = SkyFrameData.empty
            frame.observerLocation = Self.observer
            frame.julianDay = jd
            frame.nowJulianDay = jd          // real time: the accuracy gate passes
            frame.cameraCenter = look.horizontal
            frame.cameraFieldOfViewDegrees = fov
            frame.viewportSize = Self.viewport
            frame.sunHorizontal = HorizontalCoordinate(altitudeDegrees: -40, azimuthDegrees: 0)
            frame.satellitesEnabled = true
            frame.satelliteSnapshot = elapsed < tick ? first : second
            frame.satelliteDescriptors = descriptors

            var builder = SkyGeometryBuilder(frameData: frame)
            builder.run()
            guard let marker = builder.pointVertices.first(where: {
                $0.shape == PointSpriteShape.satellite.rawValue
            }) else {
                elapsed += frameSeconds
                continue
            }

            // NDC spans -1...1 across the viewport, so half the viewport is one
            // NDC unit on each axis.
            let error = SIMD2(
                Double(marker.positionNDC.x) * Double(Self.viewport.width) / 2,
                Double(marker.positionNDC.y) * Double(Self.viewport.height) / 2
            )
            result.worstErrorPixels = max(result.worstErrorPixels, simd_length(error))
            if let previous = previousError {
                result.worstStepPixels = max(
                    result.worstStepPixels, simd_length(error - previous)
                )
            }
            previousError = error
            result.frames += 1
            elapsed += frameSeconds
        }
        return result
    }

    /// **The regression.** At the tightest field the camera allows, the drawn
    /// satellite must track the truth to well under a pixel and must never
    /// step when a snapshot lands.
    func testAtTheTightestFieldTheMarkerNeitherDriftsNorJumps() throws {
        let before = try trace(fieldOfViewDegrees: Camera.minFieldOfView, subTick: false)
        let after = try trace(fieldOfViewDegrees: Camera.minFieldOfView, subTick: true)

        XCTAssertGreaterThan(before.frames, 40)
        XCTAssertEqual(after.frames, before.frames)

        report(String(
            format: "FOV %.2f deg over %d frames — extrapolated: worst error %.2f px, worst step %.2f px"
                + " | interpolated: worst error %.3f px, worst step %.3f px",
            Camera.minFieldOfView, before.frames,
            before.worstErrorPixels, before.worstStepPixels,
            after.worstErrorPixels, after.worstStepPixels
        ))

        // The bug, pinned so that it cannot quietly come back: with plain
        // extrapolation the marker measurably steps when the snapshot lands.
        // A third of a pixel does not sound like much until you remember it
        // happens two and a half times a second, in the same direction, on a
        // marker only a few pixels across — and that this is a *good* case.
        // `testTheTickBoundaryJumpAcrossTheWholeCatalogue` measures the tail.
        XCTAssertGreaterThan(before.worstStepPixels, 0.15,
                             "the extrapolation-only case no longer steps — has the "
                             + "zoom limit or the tick rate changed?")

        // And the fix: the step is gone, not merely smaller.
        // A twentieth of a pixel: the residual is no longer a step, it is the
        // interpolation and the truth disagreeing in the last decimal place.
        XCTAssertLessThan(after.worstStepPixels, 0.05,
                          "the marker stepped \(after.worstStepPixels) px at a tick boundary")
        XCTAssertLessThan(after.worstErrorPixels, 0.05,
                          "the marker drifted \(after.worstErrorPixels) px from the truth")
        XCTAssertLessThan(after.worstStepPixels, before.worstStepPixels / 10)
    }

    /// **The size of the problem, over the real catalogue rather than one
    /// orbit.** For every object above the horizon, how far the drawn point
    /// has to be corrected when a fresh snapshot lands, converted to pixels at
    /// the camera's tightest field.
    ///
    /// This is the number the fix exists for, and it is also a correction to a
    /// plausible-sounding estimate: a few metres of error at a few hundred
    /// kilometres would be several pixels here, but SGP4's actual
    /// straight-line error over 0.4 s is a fraction of a metre for ordinary
    /// low orbits, so the step is a fifth of a pixel typically and just over
    /// one at worst. Small — and still the difference between a marker that
    /// glides and one that twitches 2.5 times a second.
    func testTheTickBoundaryJumpAcrossTheWholeCatalogue() throws {
        guard let url = Bundle.main.url(forResource: "satellites", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("satellite catalogue unavailable in this bundle")
        }
        let satellites = TwoLineElement.parseCatalog(text)
            .prefix(6_000).compactMap(Satellite.init(tle:))
        try XCTSkipIf(satellites.isEmpty, "no satellites parsed")

        let tick = SatelliteTracker.tickInterval
        let tickDays = tick / 86_400.0
        let jd0 = satellites.map(\.epochJulianDay).sorted()[satellites.count / 2]
        // Pixels per radian at the tightest field, on this viewport.
        let pixelsPerRadian = Double(Self.viewport.width)
            / Angle.degreesToRadians(Camera.minFieldOfView)

        var jumps: [Double] = []
        for step in 0..<12 {
            let jd = jd0 + Double(step) * (37.0 / 86_400.0)
            let observerPosition = TopocentricTransform.observerPositionTEME(
                observer: Self.observer, julianDay: jd
            )
            for satellite in satellites {
                guard let start = satellite.propagate(julianDay: jd),
                      let end = satellite.propagate(julianDay: jd + tickDays) else { continue }
                let look = TopocentricTransform.lookAngles(
                    satellitePositionTEME: start.position,
                    observer: Self.observer, julianDay: jd
                )
                guard look.horizontal.altitudeDegrees > 5 else { continue }
                let range = simd_length(start.position - observerPosition)
                guard range > 0 else { continue }
                // What the old scheme has to correct at the tick boundary.
                let error = simd_distance(
                    start.position + start.velocity * tick, end.position
                )
                jumps.append(error / range * pixelsPerRadian)
            }
        }

        try XCTSkipIf(jumps.count < 500, "too few above-horizon samples")
        jumps.sort()
        func percentile(_ p: Double) -> Double {
            jumps[min(jumps.count - 1, Int(Double(jumps.count - 1) * p))]
        }
        report(String(
            format: "tick-boundary jump at FOV %.2f deg over %d above-horizon samples: "
                + "median %.3f px, p90 %.3f px, p99 %.3f px, max %.3f px",
            Camera.minFieldOfView, jumps.count,
            percentile(0.5), percentile(0.9), percentile(0.99), jumps[jumps.count - 1]
        ))

        // The regression: this is what the 0.15-degree zoom limit turned a
        // hundredth of a pixel into. If it ever drops below a tenth of a pixel
        // the interpolation has stopped being worth its cost and should go.
        XCTAssertGreaterThan(percentile(0.9), 0.1,
                             "the extrapolation error is no longer worth a pixel anywhere")
        // The interpolated scheme's equivalent is exactly zero — it lands on
        // the next snapshot by construction — which
        // `testAgainstRealOrbitsTheTickBoundaryResidualIsZero` pins directly.
    }

    /// At an ordinary field the two schemes are the same picture — which is the
    /// justification for not paying for the fix out there.
    func testAtAWideFieldTheDrawnPositionIsUnchanged() throws {
        let before = try trace(fieldOfViewDegrees: 90, subTick: false)
        let after = try trace(fieldOfViewDegrees: 90, subTick: true)
        XCTAssertGreaterThan(before.frames, 40)
        XCTAssertEqual(after.worstErrorPixels, before.worstErrorPixels, accuracy: 1e-9)
        XCTAssertLessThan(before.worstErrorPixels, 0.05)
    }
}

// MARK: - Shadow entry

/// Why satellites were vanishing, and what they do now.
///
/// The tier gate in `SkyGeometryBuilder.buildSatellites` used to ask
/// `illumination.isSunlit` — a three-way state sampled at 2.5 Hz — and drop any
/// above-horizon object that was not fully lit. The measurement in
/// `testThePenumbraCrossingTakesSeconds` is why that was wrong: the crossing
/// takes seconds, so the gate deleted the marker at the beginning of the fade
/// instead of over it.
final class SatelliteShadowEntryTests: XCTestCase {

    private static let sunDirection = SIMD3(1.0, 0.0, 0.0)
    private static let sunDistance = 149_597_870.7

    private static func shadow(at position: SIMD3<Double>) -> TopocentricTransform.ShadowState {
        TopocentricTransform.shadowState(
            satellitePositionTEME: position,
            sunDirection: sunDirection,
            sunDistanceKm: sunDistance
        )
    }

    /// The fraction has to agree with the three-way state at both ends, or the
    /// two views of the same geometry would disagree.
    func testTheFractionAgreesWithTheThreeWayStateAtBothEnds() {
        // Sunward: fully lit.
        XCTAssertEqual(Self.shadow(at: SIMD3(7_000, 0, 0)).sunlitFraction, 1.0)
        // Deep in the anti-sunward shadow, on the axis: fully dark.
        let deep = Self.shadow(at: SIMD3(-7_000, 0, 0))
        XCTAssertEqual(deep.illumination, .umbra)
        XCTAssertEqual(deep.sunlitFraction, 0.0)
        // Well off the shadow axis behind the Earth: lit.
        let clear = Self.shadow(at: SIMD3(-7_000, 12_000, 0))
        XCTAssertEqual(clear.illumination, .sunlit)
        XCTAssertEqual(clear.sunlitFraction, 1.0)
    }

    /// Sweeping outward across the terminator, the fraction must rise from 0 to
    /// 1 without ever going backwards and without a single large step — that
    /// monotone ramp *is* the fade.
    func testTheFractionRampsMonotonicallyAcrossThePenumbra() {
        var previous = -1.0
        var sawPartial = false
        var worstStep = 0.0
        var lower = 0.0

        for step in 0...4_000 {
            let offset = 6_000.0 + Double(step) * 1.0     // km off the shadow axis
            let state = Self.shadow(at: SIMD3(-7_000, offset, 0))
            XCTAssertGreaterThanOrEqual(state.sunlitFraction, previous,
                                        "fraction went backwards at \(offset) km")
            if previous >= 0 { worstStep = max(worstStep, state.sunlitFraction - previous) }
            if state.sunlitFraction > 0 && state.sunlitFraction < 1 {
                sawPartial = true
                XCTAssertEqual(state.illumination, .penumbra)
            }
            if state.sunlitFraction <= 0 { lower = offset }
            previous = state.sunlitFraction
        }
        XCTAssertTrue(sawPartial, "no partial illumination anywhere across the terminator")
        XCTAssertEqual(previous, 1.0)
        XCTAssertLessThan(worstStep, 0.05, "the ramp is not smooth: worst step \(worstStep)")
        report(String(format: "penumbral annulus at 7000 km begins %.0f km off the shadow axis", lower))
    }

    /// **The disappearance, measured.** Nine seconds is not an instant, and a
    /// gate that switches at the first non-sunlit sample is a marker that
    /// vanishes mid-pass. This pins the physical fact the fix rests on.
    func testThePenumbraCrossingTakesSeconds() throws {
        guard let url = Bundle.main.url(forResource: "satellites", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("satellite catalogue unavailable in this bundle")
        }
        let elements = TwoLineElement.parseCatalog(text)
        // A representative slice; the full catalogue would make this a
        // multi-minute test for a number that does not depend on the sample.
        let satellites = elements.prefix(800).compactMap(Satellite.init(tle:))
        try XCTSkipIf(satellites.isEmpty, "no satellites parsed")

        let jd0 = satellites.map(\.epochJulianDay).sorted()[satellites.count / 2]
        let sunEquatorial = SunPosition.equatorialCoordinate(julianDay: jd0)
        let sunDirection = TopocentricTransform.sunDirection(equatorial: sunEquatorial)
        let sunDistance = SunPosition.radiusVectorAU(julianDay: jd0)
            * AstronomicalConstants.astronomicalUnitKilometres
        let tickDays = SatelliteTracker.tickInterval / 86_400.0

        // Runs of consecutive ticks spent in the penumbra, over four minutes.
        var runs: [Int] = []
        for satellite in satellites {
            var run = 0
            for tick in 0..<450 {
                guard let state = satellite.propagate(julianDay: jd0 + Double(tick) * tickDays)
                else { continue }
                let shadow = TopocentricTransform.shadowState(
                    satellitePositionTEME: state.position,
                    sunDirection: sunDirection,
                    sunDistanceKm: sunDistance
                )
                if shadow.illumination == .penumbra {
                    run += 1
                } else if run > 0 {
                    runs.append(run); run = 0
                }
            }
            if run > 0 { runs.append(run) }
        }

        try XCTSkipIf(runs.count < 20, "too few shadow crossings in the sampled window")
        runs.sort()
        let median = Double(runs[runs.count / 2]) * SatelliteTracker.tickInterval
        report(String(format: "penumbra crossings: %d observed, median %.1f s, "
                     + "quartiles %.1f s / %.1f s",
                     runs.count, median,
                     Double(runs[runs.count / 4]) * SatelliteTracker.tickInterval,
                     Double(runs[3 * runs.count / 4]) * SatelliteTracker.tickInterval))

        XCTAssertGreaterThan(median, 2.0,
                             "the penumbra crossing is a fade lasting seconds — if this is now "
                             + "sub-second, the reason for fading rather than switching is gone")
    }

    /// End to end: a satellite crossing into shadow must fade out over its
    /// penumbra crossing rather than being deleted the moment it stops being
    /// fully lit.
    func testAFadingSatelliteIsDrawnDimmerRatherThanDropped() {
        let observer = GeographicLocation(latitudeDegrees: 0, longitudeDegrees: 0)
        let julianDay = 2_461_055.708333

        /// Alpha of the drawn marker for a satellite at `fraction` of full sun,
        /// or nil when it is not drawn at all.
        func alpha(sunlitFraction: Float, illumination: TopocentricTransform.Illumination) -> Float? {
            // Place the satellite straight up from the observer so it is high
            // in the sky, clear of the terrain profile.
            let observerFrame = TopocentricTransform.ObserverFrame(
                observer: observer, julianDay: julianDay
            )
            _ = observerFrame
            let up = TopocentricTransform.observerPositionTEME(
                observer: observer, julianDay: julianDay
            )
            let position = up * (7_000.0 / simd_length(up))

            let sample = SatelliteSample(
                index: 0, catalogNumber: 12_345, regime: .lowEarth, isNotable: false,
                epochJulianDay: julianDay,
                position: position, velocity: SIMD3(0, 0, 0),
                illumination: illumination,
                altitudeDegreesAtSnapshot: 90,
                sunlitFraction: sunlitFraction
            )
            var frame = SkyFrameData.empty
            frame.observerLocation = observer
            frame.julianDay = julianDay
            frame.nowJulianDay = julianDay
            frame.cameraCenter = HorizontalCoordinate(altitudeDegrees: 90, azimuthDegrees: 0)
            frame.cameraFieldOfViewDegrees = 60
            frame.viewportSize = CGSize(width: 1512, height: 900)
            frame.sunHorizontal = HorizontalCoordinate(altitudeDegrees: -40, azimuthDegrees: 0)
            frame.satellitesEnabled = true
            frame.satelliteSnapshot = SatelliteSnapshot(
                julianDay: julianDay, samples: [sample], propagationDuration: 0, altitudeOrder: [0]
            )
            frame.satelliteDescriptors = [SatelliteDescriptor(
                catalogNumber: 12_345, name: "FADER", regime: .lowEarth,
                internationalDesignator: "20-1A", epochJulianDay: julianDay, isNotable: false
            )]
            var builder = SkyGeometryBuilder(frameData: frame)
            builder.run()
            return builder.pointVertices.first {
                $0.shape == PointSpriteShape.satellite.rawValue
            }?.color.w
        }

        guard let full = alpha(sunlitFraction: 1.0, illumination: .sunlit) else {
            return XCTFail("a fully sunlit overhead satellite was not drawn at all")
        }
        XCTAssertGreaterThan(full, 0.9)

        // The regression: at the *first* moment of partial shadow the marker
        // must still be there, and at nearly full brightness — this is the
        // instant the old gate deleted it.
        guard let entering = alpha(sunlitFraction: 0.98, illumination: .penumbra) else {
            return XCTFail("the satellite vanished the moment it stopped being fully sunlit")
        }
        XCTAssertLessThan(abs(entering - full), 0.05,
                          "brightness stepped on entering the penumbra: \(full) -> \(entering)")

        // Through the crossing it dims monotonically, in small steps...
        var previous = full
        for percent in stride(from: 95, through: 20, by: -5) {
            guard let value = alpha(
                sunlitFraction: Float(percent) / 100, illumination: .penumbra
            ) else {
                return XCTFail("dropped at \(percent)% illumination instead of fading")
            }
            XCTAssertLessThanOrEqual(value, previous + 1e-5, "brightened at \(percent)%")
            XCTAssertLessThan(previous - value, 0.15, "brightness stepped at \(percent)%")
            previous = value
        }
        // ...to the point where the existing visibility floor takes over, which
        // it does at a couple of percent alpha — far too faint to read as a
        // marker vanishing.
        XCTAssertLessThan(previous, 0.25,
                          "still at \(previous) alpha near the end of the fade")

        // ...and only once it is genuinely in the umbra does it stop being
        // drawn, which is correct: an eclipsed satellite is not visible from
        // the ground, and that is a fact about the sky rather than a bug.
        XCTAssertNil(alpha(sunlitFraction: 0.0, illumination: .umbra),
                     "an eclipsed satellite above the horizon should not be drawn")
    }
}

// MARK: - Things that turned out to be correct

/// Two behaviours investigated as candidate causes of the disappearance that
/// measurement cleared. These tests exist so nobody has to investigate them
/// twice — and so that if the numbers ever change, that shows up here.
final class SatelliteCullingHeadroomTests: XCTestCase {

    /// The altitude band is searched on `altitudeDegreesAtSnapshot`, which is up
    /// to one tick stale while the drawn position has moved on. It cannot drop a
    /// visible satellite, because the band carries ten degrees of slack and the
    /// worst altitude change any object in the catalogue manages in one tick is
    /// well under half a degree. Measured, not assumed.
    func testTheStaleAltitudeBandHasAmpleHeadroom() throws {
        guard let url = Bundle.main.url(forResource: "satellites", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("satellite catalogue unavailable in this bundle")
        }
        let observer = GeographicLocation(latitudeDegrees: 37.77, longitudeDegrees: -122.42)
        let satellites = TwoLineElement.parseCatalog(text)
            .prefix(4_000).compactMap(Satellite.init(tle:))
        try XCTSkipIf(satellites.isEmpty, "no satellites parsed")

        let jd = satellites.map(\.epochJulianDay).sorted()[satellites.count / 2]
        let tickDays = SatelliteTracker.tickInterval / 86_400.0
        var worst = 0.0
        for satellite in satellites {
            guard let a = satellite.propagate(julianDay: jd),
                  let b = satellite.propagate(julianDay: jd + tickDays) else { continue }
            let altA = TopocentricTransform.lookAngles(
                satellitePositionTEME: a.position, observer: observer, julianDay: jd
            ).horizontal.altitudeDegrees
            let altB = TopocentricTransform.lookAngles(
                satellitePositionTEME: b.position, observer: observer, julianDay: jd + tickDays
            ).horizontal.altitudeDegrees
            worst = max(worst, abs(altB - altA))
        }
        report(String(format: "worst altitude change in one %.1f s tick: %.3f deg (band slack is 10)",
                     SatelliteTracker.tickInterval, worst))
        XCTAssertGreaterThan(worst, 0.01, "nothing moved — is the propagation actually running?")
        XCTAssertLessThan(worst, 5.0,
                          "objects now move \(worst) deg per tick; the geometry builder's "
                          + "10-degree band slack is no longer obviously safe")
    }

    /// The propagator does refuse some objects — but consistently, not
    /// intermittently. Over six hours of the bundled catalogue exactly two of
    /// sixteen thousand objects changed their mind, and both are decaying. So
    /// intermittent SGP4 rejection is not what makes satellites disappear, and
    /// suppressing it would mean drawing positions the model refused to produce.
    func testPropagationRejectionIsStableRatherThanIntermittent() throws {
        guard let url = Bundle.main.url(forResource: "satellites", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("satellite catalogue unavailable in this bundle")
        }
        let satellites = TwoLineElement.parseCatalog(text)
            .prefix(2_000).compactMap(Satellite.init(tle:))
        try XCTSkipIf(satellites.isEmpty, "no satellites parsed")

        let jd0 = satellites.map(\.epochJulianDay).sorted()[satellites.count / 2]
        let stepDays = 20.0 / 86_400.0
        var previous = [Bool](repeating: false, count: satellites.count)
        var flipped = 0
        for step in 0..<180 {                      // one hour, 20-second steps
            let jd = jd0 + Double(step) * stepDays
            for (i, satellite) in satellites.enumerated() {
                let ok = satellite.propagate(julianDay: jd) != nil
                if step > 0 && ok != previous[i] { flipped += 1 }
                previous[i] = ok
            }
        }
        report("propagation acceptance changes over one hour, \(satellites.count) satellites: \(flipped)")
        XCTAssertLessThan(flipped, satellites.count / 100,
                          "\(flipped) acceptance flips — intermittent rejection has become "
                          + "common enough to be worth handling")
    }
}

// MARK: - Layout

final class SatelliteSampleLayoutTests: XCTestCase {

    /// `SatelliteSample` is built sixteen thousand times per tick and walked
    /// every frame, so its size is a real budget. The sunlit fraction was added
    /// as a `Float` immediately after `isNotable` specifically to land in
    /// padding that already existed; if a later edit reorders the fields or
    /// widens it, the wide-field scan gets slower for no visible reason and
    /// this is where that shows up.
    func testAddingTheSunlitFractionDidNotGrowTheSample() {
        XCTAssertLessThanOrEqual(MemoryLayout<SatelliteSample>.stride, 128,
                                 "SatelliteSample is now "
                                 + "\(MemoryLayout<SatelliteSample>.stride) bytes")
        report("SatelliteSample: size \(MemoryLayout<SatelliteSample>.size), "
              + "stride \(MemoryLayout<SatelliteSample>.stride)")
    }
}
