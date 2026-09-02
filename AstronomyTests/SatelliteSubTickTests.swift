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
        print(String(format: "tick-boundary residual over %d orbits: linear %.3f m, interpolated %.3e m",
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

    /// A real, moderately eccentric near-Earth object from the verification
    /// set. Eccentric on purpose: the near-circular workhorses extrapolate
    /// well, and the report was that *some* satellites jump, not all.
    private static let line1 = "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753"
    private static let line2 = "2 00005  34.2682 348.7242 1859667 331.7664  19.3264 10.82419157413667"

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

        // Find an instant at which the object is well up, so it is genuinely
        // drawn (above the horizon, clear of the terrain profile).
        var baseJD = tle.epochJulianDay
        var found = false
        for step in 0..<4_000 {
            let jd = tle.epochJulianDay + Double(step) * (60.0 / 86_400.0)
            guard let state = satellite.propagate(julianDay: jd) else { continue }
            let look = TopocentricTransform.lookAngles(
                satellitePositionTEME: state.position, observer: Self.observer, julianDay: jd
            )
            if look.horizontal.altitudeDegrees > 55 { baseJD = jd; found = true; break }
        }
        try XCTSkipUnless(found, "object never rises high enough in the search window")

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

        print(String(
            format: "FOV %.2f deg over %d frames — extrapolated: worst error %.2f px, worst step %.2f px"
                + " | interpolated: worst error %.3f px, worst step %.3f px",
            Camera.minFieldOfView, before.frames,
            before.worstErrorPixels, before.worstStepPixels,
            after.worstErrorPixels, after.worstStepPixels
        ))

        // The bug, pinned so that it cannot quietly come back: plain
        // extrapolation is visibly wrong here.
        XCTAssertGreaterThan(before.worstStepPixels, 1.0,
                             "the extrapolation-only case no longer jumps — has the "
                             + "zoom limit or the tick rate changed?")

        // And the fix.
        XCTAssertLessThan(after.worstStepPixels, 0.25,
                          "the marker stepped \(after.worstStepPixels) px at a tick boundary")
        XCTAssertLessThan(after.worstErrorPixels, 0.5,
                          "the marker drifted \(after.worstErrorPixels) px from the truth")
        XCTAssertLessThan(after.worstStepPixels, before.worstStepPixels / 5)
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
