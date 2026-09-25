//
//  Refraction.swift
//  Astronomy
//
//  Atmospheric refraction: the atmosphere bends light downward, so every
//  object appears *higher* than its geometric altitude — by about 0.1° at
//  10°, and by 34' (more than a Moon diameter) right on the horizon. The
//  setting Sun you see touching the sea is geometrically already below it.
//
//  Why it is in the render path and not merely the info panel: the rise and
//  set times this app prints (`RiseSetCalculator`) already include it — the
//  Sun "sets" at a geometric altitude of −0.8333° precisely because refraction
//  lifts its upper limb to the horizon at that moment. Without refraction in
//  the drawing, the time bar said "sunset" while the disk sat most of a
//  degree below the skyline. Drawing what the times describe is the point.
//
//  Formula: Sæmundsson (Sky & Telescope, 1986), as given by Meeus,
//  "Astronomical Algorithms", 2nd ed., eq. 16.4, for the refraction R as a
//  function of the *true* altitude h (degrees):
//
//      R = 1.02 / tan(h + 10.3 / (h + 5.11))   arcminutes
//
//  plus Meeus's constant 0.0019279' so R is exactly zero at the zenith. Valid
//  for a standard atmosphere (1010 mb, 10 °C); the app has no barometer, so
//  no pressure/temperature scaling is attempted. Accuracy is a few arcseconds
//  above 15° and a fraction of an arcminute at the horizon, where the true
//  value depends on the day's weather anyway.
//
//  Below the horizon there is no physical answer — the see-through-Earth view
//  is not a sightline through air — so the correction is faded smoothly to
//  zero between −1° and −4°, keeping an object that sets continuous rather
//  than stepping when it crosses the skyline.
//

import Foundation
import simd

enum Refraction {

    /// Refraction in degrees for a true altitude in degrees, standard
    /// atmosphere. Zero at the zenith, 0.48° (28.8') at h = 0, faded to zero
    /// below −4°.
    static func refractionDegrees(trueAltitudeDegrees h: Double) -> Double {
        let clamped = max(-1.0, h)
        let argument = clamped + 10.3 / (clamped + 5.11)
        let arcminutes = 1.02 / tan(Angle.degreesToRadians(argument)) + 0.0019279
        let fade: Double
        if h >= -1.0 {
            fade = 1.0
        } else if h <= -4.0 {
            fade = 0.0
        } else {
            let t = (h + 4.0) / 3.0
            fade = t * t * (3 - 2 * t)
        }
        return max(0.0, arcminutes / 60.0) * fade
    }

    /// Apparent altitude (degrees) for a true altitude.
    static func apparentAltitudeDegrees(trueAltitudeDegrees h: Double) -> Double {
        h + refractionDegrees(trueAltitudeDegrees: h)
    }

    /// True altitude for an apparent one, by fixed-point iteration of the
    /// forward formula.
    ///
    /// Twelve iterations rather than the three the map's near-identity
    /// suggests: near the horizon dR/dh approaches −0.3, so the iteration
    /// converges geometrically at only about a factor of three per step and
    /// four steps leave a residual of an arcsecond or so — small, but this is
    /// the function that answers "what is the true altitude of the thing I can
    /// see", and it should not be the least accurate step in the chain.
    static func trueAltitudeDegrees(apparentAltitudeDegrees ha: Double) -> Double {
        var h = ha
        for _ in 0..<12 {
            h = ha - refractionDegrees(trueAltitudeDegrees: h)
        }
        return h
    }

    /// A horizontal coordinate lifted by refraction.
    static func apparent(_ horizontal: HorizontalCoordinate) -> HorizontalCoordinate {
        HorizontalCoordinate(
            altitudeDegrees: apparentAltitudeDegrees(trueAltitudeDegrees: horizontal.altitudeDegrees),
            azimuthDegrees: horizontal.azimuthDegrees
        )
    }

    // MARK: - Per-object fast path

    /// Refraction as a lookup on the vertical component of a horizontal-frame
    /// unit vector, for the renderer.
    ///
    /// The projector handles a few thousand directions per frame as unit
    /// vectors (X east, Y zenith, Z south) and never forms an altitude. `y` is
    /// sin(altitude), so the correction can be tabulated against `y` directly:
    /// each entry stores the apparent `y'` = sin(h + R) and the factor
    /// cos(h + R) / cos(h) that rescales the horizontal components to keep the
    /// vector unit. One index computation and two linear interpolations per
    /// object, no trigonometry.
    ///
    /// Resolution: 16,384 entries over y ∈ [−0.1, 1]. The interpolation error
    /// is largest at the horizon, where R changes fastest, and there it is
    /// about 1" — a tenth of a pixel at the narrowest field.
    struct Table: Sendable {
        static let shared = Table()

        private static let count = 16_384
        private static let minimumY = -0.1
        private static let span = 1.1

        private let apparentY: [Double]
        private let horizontalScale: [Double]
        /// Bounds-check-free views of the two arrays above.
        ///
        /// Safe, and narrowly so: `Table` is a `let` singleton that is never
        /// deallocated, both arrays are `let` and never mutated after `init`,
        /// and the pointers are only ever read at indices clamped into range
        /// by `apparent(direction:)`. This is the one place in the render path
        /// where the bounds check was worth removing — it sits inside a lookup
        /// that runs several thousand times per frame, twice per call.
        private let apparentYBuffer: UnsafePointer<Double>
        private let horizontalScaleBuffer: UnsafePointer<Double>

        private init() {
            var ys: [Double] = []
            var scales: [Double] = []
            ys.reserveCapacity(Self.count)
            scales.reserveCapacity(Self.count)
            for i in 0..<Self.count {
                let y = Self.minimumY + Self.span * Double(i) / Double(Self.count - 1)
                let h = asin(max(-1.0, min(1.0, y)))
                let hDegrees = Angle.radiansToDegrees(h)
                let apparent = h + Angle.degreesToRadians(refractionDegrees(trueAltitudeDegrees: hDegrees))
                ys.append(sin(apparent))
                let cosH = cos(h)
                scales.append(cosH > 1e-9 ? cos(apparent) / cosH : 1.0)
            }
            apparentY = ys
            horizontalScale = scales
            let yStorage = UnsafeMutablePointer<Double>.allocate(capacity: ys.count)
            yStorage.update(from: ys, count: ys.count)
            apparentYBuffer = UnsafePointer(yStorage)
            let scaleStorage = UnsafeMutablePointer<Double>.allocate(capacity: scales.count)
            scaleStorage.update(from: scales, count: scales.count)
            horizontalScaleBuffer = UnsafePointer(scaleStorage)
        }

        /// The direction lifted by refraction. Directions more than a few
        /// degrees below the horizon come back unchanged.
        @inline(__always)
        func apparent(direction d: SIMD3<Double>) -> SIMD3<Double> {
            let y = d.y
            if y <= Self.minimumY { return d }
            let position = (y - Self.minimumY) / Self.span * Double(Self.count - 1)
            let index = min(Self.count - 2, max(0, Int(position)))
            let fraction = min(1.0, max(0.0, position - Double(index)))
            let y0 = apparentYBuffer[index], y1 = apparentYBuffer[index + 1]
            let s0 = horizontalScaleBuffer[index], s1 = horizontalScaleBuffer[index + 1]
            let newY = y0 + (y1 - y0) * fraction
            let scale = s0 + (s1 - s0) * fraction
            return SIMD3(d.x * scale, newY, d.z * scale)
        }
    }
}
