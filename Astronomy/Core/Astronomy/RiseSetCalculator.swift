//
//  RiseSetCalculator.swift
//  Astronomy
//
//  Times at which a body's altitude crosses a given "standard altitude", plus
//  the time and altitude of its transit (culmination).
//
//  Reference: Jean Meeus, "Astronomical Algorithms", 2nd ed., Chapter 15
//  ("Rising, Transit, and Setting"), for the standard altitudes h0 and for the
//  principle that rise/set is the solution of
//
//      h(t) = h0
//
//  where h(t) is the body's topocentric apparent altitude.
//
//  Method — and why it is not Meeus's own three-value interpolation.
//  ----------------------------------------------------------------
//  Meeus 15.2 interpolates the body's apparent position from three ephemeris
//  entries at 0h, 24h and 48h TD and solves for the crossing with one
//  Newton-like correction. That form exists because it was written for someone
//  reading positions out of a printed almanac: three lines of a table are all
//  the input you get. Here the ephemeris is a function — `SunPosition`,
//  `MoonPosition`, `PlanetPosition`, or a fixed catalogue position — that can
//  be evaluated at any instant for a few microseconds, so the almanac
//  constraint does not apply and the interpolation is pure downside: it is the
//  part of Meeus's recipe that carries the error, and it degrades exactly where
//  the body moves fastest (the Moon) and where the crossing is most oblique
//  (high latitudes, near-circumpolar objects).
//
//  What is implemented instead is the same equation solved directly:
//
//    1. Sample h(t) on a uniform grid across the search window. Every sample
//       re-evaluates the body's position, so the object's own motion over the
//       night is fully accounted for — no linear-motion assumption anywhere.
//    2. Every grid interval whose endpoints straddle h0 brackets a crossing.
//       Bisect it to `convergenceDays` (see below). Bisection cannot diverge,
//       which matters precisely in the awkward cases Newton's method fails on:
//       a grazing circumpolar object, or an observer inside the polar circle.
//    3. Transit is the maximum of h(t), located by ternary search on the
//       bracket around the best grid sample. `h` is unimodal within one
//       diurnal cycle, which is what ternary search needs.
//
//  Awkward cases are reported rather than papered over. If no interval
//  straddles h0 across a whole day the body never crosses the horizon, and
//  `Circumstance` distinguishes "always up" (min altitude above h0) from "never
//  up" (max altitude below h0). At high latitude the same machinery answers the
//  Sun honestly: in a Tromsø June there is no sunset, and the twilight query
//  returns `.alwaysUp` rather than inventing a time.
//

import Foundation

enum RiseSetCalculator {

    // MARK: - Standard altitudes (Meeus 15.1)

    /// The altitude of the *geometric* centre of a body at the moment its
    /// apparent position touches the horizon.
    enum StandardAltitude {

        /// Stars, planets and deep-sky objects: -34 arcminutes, the standard
        /// value of atmospheric refraction at the horizon (Meeus 15.1).
        static let point: Double = -0.5667

        /// The Sun: refraction plus the Sun's mean semidiameter (16'), since
        /// "sunrise" is the appearance of the *upper limb* (Meeus 15.1).
        static let sun: Double = -0.8333

        /// Civil, nautical and astronomical twilight, defined by convention as
        /// the Sun's centre at -6, -12 and -18 degrees. These are definitions,
        /// not physics, so no refraction term applies.
        static let civilTwilight: Double = -6
        static let nauticalTwilight: Double = -12
        static let astronomicalTwilight: Double = -18

        /// The Moon: `h0 = 0.7275 * pi - 34'` (Meeus 15.1), where `pi` is the
        /// equatorial horizontal parallax, `sin(pi) = 6378.14 / delta`. The
        /// parallax term is large — around +57' — so the Moon rises visibly
        /// earlier than a star in the same place, and using the point value for
        /// it would be wrong by several minutes.
        static func moon(distanceKilometres: Double) -> Double {
            let parallaxDegrees = Angle.radiansToDegrees(
                asin(min(1.0, 6378.14 / max(distanceKilometres, 1.0)))
            )
            return 0.7275 * parallaxDegrees - 0.5667
        }
    }

    // MARK: - Result

    /// Which of the three qualitatively different things a body can do over the
    /// search window.
    enum Circumstance: String {
        /// Crosses the standard altitude: `rise` and/or `set` are populated.
        case risesAndSets
        /// Never drops to the standard altitude — circumpolar for this
        /// observer, or (for the Sun) a polar day / a night that never darkens.
        case alwaysUp
        /// Never reaches the standard altitude at all over the window.
        case neverUp
    }

    struct Result {
        /// Julian Day of the first upward crossing in the window, if any.
        let riseJulianDay: Double?
        /// Julian Day of the first downward crossing in the window, if any.
        let setJulianDay: Double?
        /// Julian Day of maximum altitude within the window.
        let transitJulianDay: Double
        /// Altitude at `transitJulianDay`, in degrees.
        let transitAltitudeDegrees: Double
        /// Minimum altitude reached over the window, in degrees. This is what
        /// separates "circumpolar" from "just did not cross today".
        let minimumAltitudeDegrees: Double
        let circumstance: Circumstance

        var isCircumpolar: Bool { circumstance == .alwaysUp }
        var neverRises: Bool { circumstance == .neverUp }
    }

    // MARK: - Tunables

    /// Grid step for the bracketing pass, in days. Ten minutes.
    ///
    /// The grid only has to be fine enough that no crossing pair is missed —
    /// i.e. finer than the shortest time the body can spend on the wrong side
    /// of `h0`. The fastest thing here that crosses a horizon is the Moon at
    /// about 15 degrees of altitude per hour near the equator, so ten minutes
    /// is roughly 2.5 degrees of altitude per step: two orders of magnitude
    /// away from missing a crossing, and cheap (145 evaluations per day).
    ///
    /// Satellites are deliberately *not* served by this: one crosses the whole
    /// sky in minutes and needs its own cadence (see `SkyPath`).
    static let bracketStepDays: Double = 10.0 / 1440.0

    /// Bisection stops here: 1e-6 days is 0.086 seconds, well below the
    /// accuracy of any ephemeris in this app.
    static let convergenceDays: Double = 1e-6

    // MARK: - Core solver

    /// Solves `altitude(t) == standardAltitudeDegrees` over
    /// `[start, start + durationDays]`.
    ///
    /// `altitudeDegrees` is evaluated afresh at every sample, so a body that
    /// moves during the window (the Moon most of all) is handled exactly, with
    /// no assumption that its RA/Dec are constant.
    static func solve(
        altitudeDegrees: (Double) -> Double,
        standardAltitudeDegrees: Double,
        startJulianDay start: Double,
        durationDays: Double = 1.0
    ) -> Result {
        precondition(durationDays > 0)
        let steps = max(2, Int((durationDays / bracketStepDays).rounded(.up)))
        let step = durationDays / Double(steps)

        var rise: Double?
        var set: Double?
        var bestAltitude = -Double.infinity
        var bestIndex = 0
        var minimumAltitude = Double.infinity

        var previousTime = start
        var previousAltitude = altitudeDegrees(previousTime)
        bestAltitude = previousAltitude
        minimumAltitude = previousAltitude

        for i in 1...steps {
            let time = start + Double(i) * step
            let altitude = altitudeDegrees(time)

            if altitude > bestAltitude {
                bestAltitude = altitude
                bestIndex = i
            }
            minimumAltitude = min(minimumAltitude, altitude)

            let wasBelow = previousAltitude < standardAltitudeDegrees
            let isBelow = altitude < standardAltitudeDegrees
            if wasBelow != isBelow {
                let crossing = bisect(
                    altitudeDegrees: altitudeDegrees,
                    standardAltitudeDegrees: standardAltitudeDegrees,
                    lower: previousTime,
                    upper: time,
                    lowerIsBelow: wasBelow
                )
                if wasBelow {
                    if rise == nil { rise = crossing }
                } else {
                    if set == nil { set = crossing }
                }
            }

            previousTime = time
            previousAltitude = altitude
        }

        // Transit: refine the best grid sample against its two neighbours.
        // Altitude is unimodal across one diurnal cycle, so ternary search on
        // that bracket converges on the true maximum.
        let lower = start + Double(max(0, bestIndex - 1)) * step
        let upper = start + Double(min(steps, bestIndex + 1)) * step
        let (transitTime, transitAltitude) = ternaryMaximum(
            altitudeDegrees: altitudeDegrees, lower: lower, upper: upper
        )

        let circumstance: Circumstance
        if rise != nil || set != nil {
            circumstance = .risesAndSets
        } else if minimumAltitude >= standardAltitudeDegrees {
            circumstance = .alwaysUp
        } else {
            circumstance = .neverUp
        }

        return Result(
            riseJulianDay: rise,
            setJulianDay: set,
            transitJulianDay: transitTime,
            transitAltitudeDegrees: transitAltitude,
            minimumAltitudeDegrees: minimumAltitude,
            circumstance: circumstance
        )
    }

    /// Bisection on a bracketed crossing. Chosen over Newton/secant because it
    /// is unconditionally convergent: near a grazing crossing the derivative of
    /// altitude with respect to time approaches zero, which is precisely where
    /// a derivative-based method flies off, and precisely the case (a marginally
    /// circumpolar object, a high-latitude Sun) this has to get right.
    private static func bisect(
        altitudeDegrees: (Double) -> Double,
        standardAltitudeDegrees h0: Double,
        lower: Double,
        upper: Double,
        lowerIsBelow: Bool
    ) -> Double {
        var low = lower
        var high = upper
        while high - low > convergenceDays {
            let mid = 0.5 * (low + high)
            let isBelow = altitudeDegrees(mid) < h0
            if isBelow == lowerIsBelow {
                low = mid
            } else {
                high = mid
            }
        }
        return 0.5 * (low + high)
    }

    /// Ternary search for the maximum of a unimodal function.
    private static func ternaryMaximum(
        altitudeDegrees: (Double) -> Double,
        lower: Double,
        upper: Double
    ) -> (julianDay: Double, altitudeDegrees: Double) {
        var low = lower
        var high = upper
        while high - low > convergenceDays {
            let third = (high - low) / 3.0
            let a = low + third
            let b = high - third
            if altitudeDegrees(a) < altitudeDegrees(b) {
                low = a
            } else {
                high = b
            }
        }
        let mid = 0.5 * (low + high)
        return (mid, altitudeDegrees(mid))
    }

    // MARK: - Convenience entry points

    /// Rise/set/transit for a body whose equatorial position is a function of
    /// time. Use for the Sun, the Moon and the planets.
    static func events(
        equatorialAt: (Double) -> EquatorialCoordinate,
        standardAltitudeDegrees: Double,
        observer: GeographicLocation,
        startJulianDay: Double,
        durationDays: Double = 1.0
    ) -> Result {
        solve(
            altitudeDegrees: { jd in
                CoordinateTransformService.horizontal(
                    from: equatorialAt(jd), observer: observer, julianDay: jd
                ).altitudeDegrees
            },
            standardAltitudeDegrees: standardAltitudeDegrees,
            startJulianDay: startJulianDay,
            durationDays: durationDays
        )
    }

    /// Rise/set/transit for a fixed catalogue position (star, deep-sky object).
    ///
    /// The position is precessed to the equinox of date once per evaluation,
    /// which is the same treatment the renderer gives it; proper motion over a
    /// single night is many orders of magnitude below the arcminute, so the
    /// position is otherwise held fixed.
    static func events(
        fixedJ2000: EquatorialCoordinate,
        observer: GeographicLocation,
        startJulianDay: Double,
        durationDays: Double = 1.0
    ) -> Result {
        let ofDate = Precession.precess(fixedJ2000, julianDay: startJulianDay)
        return events(
            equatorialAt: { _ in ofDate },
            standardAltitudeDegrees: StandardAltitude.point,
            observer: observer,
            startJulianDay: startJulianDay,
            durationDays: durationDays
        )
    }

    /// The Sun, with the upper-limb standard altitude.
    static func sunEvents(
        observer: GeographicLocation, startJulianDay: Double, durationDays: Double = 1.0
    ) -> Result {
        events(
            equatorialAt: SunPosition.equatorialCoordinate(julianDay:),
            standardAltitudeDegrees: StandardAltitude.sun,
            observer: observer,
            startJulianDay: startJulianDay,
            durationDays: durationDays
        )
    }

    /// The Sun against a twilight boundary (-6 / -12 / -18).
    static func sunEvents(
        standardAltitudeDegrees: Double,
        observer: GeographicLocation,
        startJulianDay: Double,
        durationDays: Double = 1.0
    ) -> Result {
        events(
            equatorialAt: SunPosition.equatorialCoordinate(julianDay:),
            standardAltitudeDegrees: standardAltitudeDegrees,
            observer: observer,
            startJulianDay: startJulianDay,
            durationDays: durationDays
        )
    }

    /// The Moon, whose standard altitude is re-derived at each sample because
    /// its parallax varies by several arcminutes across a lunation.
    static func moonEvents(
        observer: GeographicLocation, startJulianDay: Double, durationDays: Double = 1.0
    ) -> Result {
        // The parallax correction is evaluated once at the window's midpoint:
        // it changes by under an arcminute over a night, which moves the
        // crossing by well under the ephemeris's own error, while keeping the
        // solver's contract (a single h0) intact.
        let midpoint = startJulianDay + durationDays * 0.5
        let h0 = StandardAltitude.moon(
            distanceKilometres: MoonPosition.distanceKilometres(julianDay: midpoint)
        )
        return events(
            equatorialAt: MoonPosition.equatorialCoordinate(julianDay:),
            standardAltitudeDegrees: h0,
            observer: observer,
            startJulianDay: startJulianDay,
            durationDays: durationDays
        )
    }
}
