//
//  SatelliteSubTick.swift
//  Astronomy
//
//  How a satellite's drawn position is filled in *between* propagation ticks,
//  and why that answer has to change with the zoom.
//
//  ## The problem the zoom limit created
//
//  The satellite layer propagates the whole catalogue with SGP4 at 2.5 Hz and,
//  on every frame in between, draws `r + v·dt`. That straight-line guess is
//  wrong by a few metres by the end of a 0.4-second tick — partly the
//  neglected quadratic term, partly the fact that SGP4's reported velocity is
//  an osculating two-body velocity rather than the exact derivative of its own
//  position function, which no amount of extra Taylor terms can fix. When the
//  next snapshot lands, the drawn point steps from the guess to the truth.
//
//  That step was invisible and is not any more, because the camera's tightest
//  field went from 3 degrees to 0.15 so that planets could actually resolve.
//  At 400 km slant range on a ~1500-point viewport:
//
//  | field of view | 3 m of error | 30 m of error |
//  |---------------|--------------|---------------|
//  | 90 degrees    |     0.01 px  |     0.07 px   |
//  | 3 degrees     |     0.21 px  |     2.15 px   |
//  | 0.15 degrees  |     4.3 px   |    43 px      |
//
//  So the design was sound at the old limit and is not at the new one, and the
//  objects with the poorest extrapolation — deep-space cases, high
//  eccentricity near perigee — jump worst. Which is exactly the report: *most*
//  satellites move smoothly, *some* jump.
//
//  ## The fix
//
//  Stop extrapolating and start *interpolating*. If the tracker propagates each
//  satellite to the end of the tick as well as the start, the renderer has two
//  positions and two velocities bracketing every frame it has to draw, and a
//  cubic Hermite through them is both far more accurate in the middle of the
//  interval and — the part that actually matters — **exactly equal to the next
//  snapshot's own position at the end of it**. There is no correction left to
//  apply at a tick boundary, so there is nothing to see.
//
//  Interpolating rather than adding a quadratic term is the whole point.
//  A second-order Taylor term removes most of the *magnitude* of the error but
//  leaves a discontinuity of the same kind, because it still never arrives at
//  the value the next tick will assert. Hermite removes the discontinuity by
//  construction.
//
//  ## Why it is gated on the field of view
//
//  The second propagation doubles the tracker's per-tick work, and at a wide
//  field it buys nothing a person can see — a hundredth of a pixel. So it is
//  requested only once the camera is narrow enough for the error to approach a
//  pixel, which is also exactly when almost nothing is on screen. The blend
//  weight ramps smoothly across the threshold instead of switching, so there is
//  no step at the moment the mode changes either.
//

import Foundation
import simd

/// Sub-tick position reconstruction for satellites, and the zoom thresholds
/// that decide how much of it is used.
enum SatelliteSubTick {

    /// At or above this field of view, plain linear extrapolation is used and
    /// no second propagation is requested. From the table above, 30 m of error
    /// at 5 degrees is around 1.3 pixels — the point at which a jump starts to
    /// be a thing rather than a rounding difference.
    static let linearOnlyFieldOfViewDegrees: Double = 5.0

    /// At or below this field of view the interpolation is used in full. One
    /// degree is where even an ordinary near-circular orbit's few metres cross
    /// a pixel.
    static let fullyInterpolatedFieldOfViewDegrees: Double = 1.0

    /// How much of the exact interpolation to mix in at this field of view:
    /// 0 wide, 1 narrow, smoothstepped across the band between the two
    /// thresholds so that zooming through it never produces a step of its own.
    static func interpolationWeight(fieldOfViewDegrees fov: Double) -> Double {
        let span = linearOnlyFieldOfViewDegrees - fullyInterpolatedFieldOfViewDegrees
        guard span > 0 else { return fov <= fullyInterpolatedFieldOfViewDegrees ? 1 : 0 }
        let t = min(1.0, max(0.0, (linearOnlyFieldOfViewDegrees - fov) / span))
        return t * t * (3 - 2 * t)
    }

    /// Whether the tracker should spend a second propagation pass on this
    /// frame's field of view. Deliberately the *same* threshold the weight
    /// starts ramping at, so no tick ever computes states that would be
    /// multiplied by zero.
    static func isWorthComputing(fieldOfViewDegrees fov: Double) -> Bool {
        fov < linearOnlyFieldOfViewDegrees
    }

    /// Cubic Hermite position on the interval `[0, h]` from the states at both
    /// ends, evaluated at `t`.
    ///
    /// Outside the interval this continues linearly from the nearer endpoint
    /// rather than letting the cubic run away: a tick that arrives late (or a
    /// scrubbed clock) must degrade to the old behaviour, not to a cubic
    /// extrapolated past its data. The two branches agree in value and slope at
    /// both ends, so the result is smooth everywhere.
    @inline(__always)
    static func position(
        start: SIMD3<Double>, startVelocity: SIMD3<Double>,
        end: SIMD3<Double>, endVelocity: SIMD3<Double>,
        interval h: Double, elapsed t: Double
    ) -> SIMD3<Double> {
        guard h > 0 else { return start + startVelocity * t }
        if t <= 0 { return start + startVelocity * t }
        if t >= h { return end + endVelocity * (t - h) }
        let s = t / h
        let s2 = s * s
        let s3 = s2 * s
        // Standard Hermite basis. h00 + h01 == 1 identically, so the position
        // is an exact affine blend of the endpoints plus the two tangent terms.
        let h00 = 2 * s3 - 3 * s2 + 1
        let h10 = s3 - 2 * s2 + s
        let h01 = -2 * s3 + 3 * s2
        let h11 = s3 - s2
        return start * h00 + startVelocity * (h10 * h)
            + end * h01 + endVelocity * (h11 * h)
    }
}
