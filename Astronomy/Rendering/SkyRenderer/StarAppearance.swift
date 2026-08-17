//
//  StarAppearance.swift
//  Astronomy
//
//  Maps physical quantities (B-V color index, apparent magnitude) to the
//  RGBA color and point size used for rendering. Approximate but
//  physically-motivated: B-V < 0 is hot/blue-white, B-V ~ 0.6 is Sun-like
//  white-yellow, B-V > 1.5 is cool/red. Not a precise blackbody model, but
//  gives believable warm/cool star colors as required by the visual spec.
//

import Foundation
import simd

enum StarAppearance {

    static func color(colorIndex: Double?) -> SIMD4<Float> {
        guard let bv = colorIndex else {
            return SIMD4(0.85, 0.88, 0.95, 1.0)
        }
        // Piecewise-linear approximation across the B-V range.
        let stops: [(Double, SIMD3<Float>)] = [
            (-0.4, SIMD3(0.61, 0.71, 1.0)),   // blue-white
            (0.0, SIMD3(0.80, 0.85, 1.0)),    // white-blue
            (0.3, SIMD3(0.98, 0.97, 0.92)),   // white
            (0.6, SIMD3(1.0, 0.93, 0.78)),    // yellow-white (Sun-like)
            (1.0, SIMD3(1.0, 0.80, 0.55)),    // orange
            (1.6, SIMD3(1.0, 0.60, 0.45)),    // red-orange
        ]

        let clamped = max(stops.first!.0, min(stops.last!.0, bv))
        for i in 0..<(stops.count - 1) {
            let (t0, c0) = stops[i]
            let (t1, c1) = stops[i + 1]
            if clamped >= t0 && clamped <= t1 {
                let t = Float((clamped - t0) / (t1 - t0))
                let mixed = mix(c0, c1, t: t)
                return SIMD4(mixed, 1.0)
            }
        }
        return SIMD4(stops.last!.1, 1.0)
    }

    private static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }

    /// Point sprite diameter in points for a given apparent magnitude.
    /// Brighter (lower/negative magnitude) stars render larger.
    static func pointSize(forMagnitude magnitude: Double) -> Float {
        let clampedMag = max(-27.0, min(6.5, magnitude))
        let size = 9.0 - (clampedMag + 1.5) * 1.15
        return Float(max(1.2, min(28.0, size)))
    }

    static let sunColor = SIMD4<Float>(1.0, 0.86, 0.4, 1.0)
    static let moonColor = SIMD4<Float>(0.85, 0.87, 0.9, 1.0)
    static let planetColor = SIMD4<Float>(0.65, 0.85, 0.55, 1.0)
    static let constellationLineColor = SIMD4<Float>(0.42, 0.55, 0.78, 0.35)
}
