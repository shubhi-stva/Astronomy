//
//  EventSolver.swift
//  Astronomy
//
//  The two numerical shapes every computed event in the calendar reduces to.
//
//  Almost nothing in an astronomy calendar is a *date*; it is the solution of
//  an equation. An equinox is a longitude crossing a threshold. A full moon is
//  an angle crossing a threshold. An opposition is a maximum of elongation. A
//  close approach is a minimum of separation. So there are exactly two solvers
//  here, and every event file above them is a choice of function and window.
//
//  The pattern is deliberately the same one `RiseSetCalculator` uses and for
//  the same reason: the ephemerides here are closed-form functions that can be
//  evaluated at any instant in microseconds, so a coarse bracketing scan
//  followed by an exact refinement is both simpler and more accurate than any
//  interpolation of tabulated values. The bracketing step is the only thing
//  that has to be chosen with care — it must be finer than the shortest
//  interval the quantity can spend on the far side of the threshold — and every
//  caller states its choice and its reasoning.
//

import Foundation

enum EventSolver {

    /// Bisection stops here. 1e-6 days is 0.09 seconds, far below the accuracy
    /// of anything being solved.
    static let convergenceDays: Double = 1e-6

    /// Signed difference between two angles, in (-180, 180].
    static func signedDelta(_ angle: Double, _ target: Double) -> Double {
        var d = (angle - target).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    // MARK: - Threshold crossings

    /// Every instant in `[start, end]` at which the increasing angular
    /// quantity `angleDegrees` passes through `targetDegrees`.
    ///
    /// The quantity is treated as an angle, so the search is for the *upward*
    /// crossing of `signedDelta(f(t), target)` through zero. The wrap from
    /// +180 back to -180 is a downward jump and is skipped, which is what makes
    /// this work on a value that is only ever known modulo 360.
    ///
    /// `stepDays` must be small enough that the quantity cannot cross and
    /// re-cross within one step. Every caller documents its choice.
    static func crossings(
        of angleDegrees: (Double) -> Double,
        targetDegrees: Double,
        from start: Double,
        to end: Double,
        stepDays: Double
    ) -> [Double] {
        precondition(stepDays > 0 && end > start)
        var results: [Double] = []
        var previousTime = start
        var previousDelta = signedDelta(angleDegrees(start), targetDegrees)

        var time = start + stepDays
        while previousTime < end {
            let clamped = min(time, end)
            let delta = signedDelta(angleDegrees(clamped), targetDegrees)
            // Upward crossing only, and only when the step did not wrap: a jump
            // of nearly 360 in one step is the modulus, not a crossing.
            if previousDelta < 0, delta >= 0, delta - previousDelta < 180 {
                results.append(
                    bisect(
                        angleDegrees: angleDegrees, targetDegrees: targetDegrees,
                        lower: previousTime, upper: clamped
                    )
                )
            }
            previousTime = clamped
            previousDelta = delta
            if clamped >= end { break }
            time += stepDays
        }
        return results
    }

    /// Bisects a bracket known to contain one upward zero of the signed delta.
    private static func bisect(
        angleDegrees: (Double) -> Double,
        targetDegrees: Double,
        lower: Double,
        upper: Double
    ) -> Double {
        var low = lower
        var high = upper
        while high - low > convergenceDays {
            let mid = (low + high) / 2
            if signedDelta(angleDegrees(mid), targetDegrees) < 0 {
                low = mid
            } else {
                high = mid
            }
        }
        return (low + high) / 2
    }

    // MARK: - Extrema

    /// Interior local minima of `value` over `[start, end]`, refined.
    ///
    /// The grid scan finds which sample is lower than both neighbours; the
    /// refinement is a golden-section search over that bracket, which needs no
    /// derivative and cannot overshoot. Endpoints are excluded deliberately: a
    /// minimum at the edge of the window is usually a minimum of the window
    /// rather than of the function, and reporting it would put a spurious
    /// "close approach" at the first and last day of every search.
    static func localMinima(
        of value: (Double) -> Double,
        from start: Double,
        to end: Double,
        stepDays: Double
    ) -> [(julianDay: Double, value: Double)] {
        precondition(stepDays > 0 && end > start)
        let steps = max(2, Int(((end - start) / stepDays).rounded(.up)))
        let step = (end - start) / Double(steps)

        var samples: [Double] = []
        samples.reserveCapacity(steps + 1)
        for i in 0...steps { samples.append(value(start + Double(i) * step)) }

        var results: [(Double, Double)] = []
        for i in 1..<steps {
            guard samples[i] <= samples[i - 1], samples[i] <= samples[i + 1] else { continue }
            let refined = goldenMinimum(
                value: value,
                lower: start + Double(i - 1) * step,
                upper: start + Double(i + 1) * step
            )
            results.append(refined)
        }
        return results.map { (julianDay: $0.0, value: $0.1) }
    }

    /// Interior local maxima, as minima of the negated function.
    static func localMaxima(
        of value: @escaping (Double) -> Double,
        from start: Double,
        to end: Double,
        stepDays: Double
    ) -> [(julianDay: Double, value: Double)] {
        localMinima(of: { -value($0) }, from: start, to: end, stepDays: stepDays)
            .map { (julianDay: $0.julianDay, value: -$0.value) }
    }

    /// Golden-section minimisation over a unimodal bracket.
    private static func goldenMinimum(
        value: (Double) -> Double, lower: Double, upper: Double
    ) -> (Double, Double) {
        let phi = (5.0.squareRoot() - 1) / 2
        var a = lower
        var b = upper
        var c = b - phi * (b - a)
        var d = a + phi * (b - a)
        var fc = value(c)
        var fd = value(d)
        while b - a > convergenceDays {
            if fc < fd {
                b = d
                d = c
                fd = fc
                c = b - phi * (b - a)
                fc = value(c)
            } else {
                a = c
                c = d
                fc = fd
                d = a + phi * (b - a)
                fd = value(d)
            }
        }
        let t = (a + b) / 2
        return (t, value(t))
    }
}
