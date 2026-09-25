//
//  SatellitePasses.swift
//  Astronomy
//
//  Pass prediction: when a satellite rises, culminates and sets for an
//  observer, and whether the pass can actually be seen.
//
//  A pass is found by sampling the satellite's altitude on a coarse grid (a
//  LEO object crosses the sky in minutes, so 20-second samples cannot miss a
//  whole pass), then refining each horizon crossing by bisection on the
//  propagator itself and locating the culmination by a ternary search on the
//  bracket. It is the same shape as `RiseSetCalculator`, for the same reason:
//  the position is a function that can be evaluated anywhere, so nothing is
//  interpolated.
//
//  "Visible" means what an observer means by it: the satellite is in sunlight
//  at culmination while the observer's Sun is below −6°. A daytime pass or one
//  that is entirely in the Earth's shadow is listed and marked, not hidden —
//  a radio operator wants the pass regardless — but the panel says which.
//

import Foundation
import simd

struct SatellitePass: Identifiable, Hashable, Sendable {
    let catalogNumber: Int
    let name: String
    let riseJulianDay: Double
    let riseAzimuthDegrees: Double
    let peakJulianDay: Double
    let peakHorizontal: HorizontalCoordinate
    let setJulianDay: Double
    let setAzimuthDegrees: Double
    /// Sunlit at culmination while the observer is in twilight or night.
    let isVisible: Bool
    /// True if the satellite is sunlit at culmination at all (it may still be
    /// a daytime pass).
    let isSunlitAtPeak: Bool

    var id: String { "\(catalogNumber)-\(riseJulianDay)" }
    var durationSeconds: Double { (setJulianDay - riseJulianDay) * 86_400 }
}

enum SatellitePassPredictor {

    /// Coarse sampling step, days. 20 s: a LEO pass lasts several minutes.
    static let coarseStepDays = 20.0 / 86_400.0
    /// Passes culminating below this are not worth listing; they are in the
    /// murk and the trees.
    static let minimumPeakAltitudeDegrees = 10.0

    /// Predicts passes for one satellite, given a closure that evaluates its
    /// geocentric TEME position at a Julian Day (nil when the propagator
    /// refuses the instant).
    static func passes(
        catalogNumber: Int,
        name: String,
        observer: GeographicLocation,
        fromJulianDay start: Double,
        spanDays: Double,
        position: (Double) -> SIMD3<Double>?,
        isSunlit: (SIMD3<Double>, Double) -> Bool
    ) -> [SatellitePass] {
        func altitude(_ jd: Double) -> Double? {
            guard let p = position(jd) else { return nil }
            return TopocentricTransform.lookAngles(
                satellitePositionTEME: p, observer: observer, julianDay: jd
            ).horizontal.altitudeDegrees
        }
        func look(_ jd: Double) -> HorizontalCoordinate? {
            guard let p = position(jd) else { return nil }
            return TopocentricTransform.lookAngles(
                satellitePositionTEME: p, observer: observer, julianDay: jd
            ).horizontal
        }
        /// Bisection for the instant altitude crosses zero between a and b.
        func crossing(_ a: Double, _ b: Double) -> Double {
            var lo = a, hi = b
            var loAlt = altitude(lo) ?? 0
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                let midAlt = altitude(mid) ?? 0
                if (midAlt > 0) == (loAlt > 0) { lo = mid; loAlt = midAlt } else { hi = mid }
            }
            return (lo + hi) / 2
        }
        func culmination(_ a: Double, _ b: Double) -> Double {
            var lo = a, hi = b
            for _ in 0..<40 {
                let m1 = lo + (hi - lo) / 3, m2 = hi - (hi - lo) / 3
                if (altitude(m1) ?? -90) < (altitude(m2) ?? -90) { lo = m1 } else { hi = m2 }
            }
            return (lo + hi) / 2
        }

        var result: [SatellitePass] = []
        var previousJD = start
        guard var previousAlt = altitude(start) else { return [] }
        var riseJD: Double? = previousAlt > 0 ? start : nil
        var jd = start + coarseStepDays
        let end = start + spanDays
        while jd <= end {
            guard let alt = altitude(jd) else { return result }
            if previousAlt <= 0, alt > 0 {
                riseJD = crossing(previousJD, jd)
            } else if previousAlt > 0, alt <= 0, let rise = riseJD {
                let set = crossing(previousJD, jd)
                let peak = culmination(rise, set)
                if let peakLook = look(peak),
                   peakLook.altitudeDegrees >= minimumPeakAltitudeDegrees,
                   let riseLook = look(rise), let setLook = look(set),
                   let peakPosition = position(peak) {
                    let sunlit = isSunlit(peakPosition, peak)
                    let sun = CoordinateTransformService.horizontal(
                        from: SunPosition.equatorialCoordinate(julianDay: peak),
                        observer: observer, julianDay: peak
                    )
                    result.append(SatellitePass(
                        catalogNumber: catalogNumber, name: name,
                        riseJulianDay: rise, riseAzimuthDegrees: riseLook.azimuthDegrees,
                        peakJulianDay: peak, peakHorizontal: peakLook,
                        setJulianDay: set, setAzimuthDegrees: setLook.azimuthDegrees,
                        isVisible: sunlit && sun.altitudeDegrees < -6,
                        isSunlitAtPeak: sunlit
                    ))
                }
                riseJD = nil
            }
            previousJD = jd
            previousAlt = alt
            jd += coarseStepDays
        }
        return result
    }
}
