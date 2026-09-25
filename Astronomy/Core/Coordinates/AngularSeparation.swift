//
//  AngularSeparation.swift
//  Astronomy
//
//  Great-circle angle between two directions, and its display form.
//

import Foundation
import simd

enum AngularSeparation {

    /// Angular distance between two equatorial positions, degrees. Uses the
    /// vector form (atan2 of cross and dot), which is accurate at every
    /// separation — the cosine formula loses digits below an arcminute, which
    /// is exactly the regime a double star or a conjunction sits in.
    static func degrees(_ a: EquatorialCoordinate, _ b: EquatorialCoordinate) -> Double {
        let v1 = Precession.unitVector(a)
        let v2 = Precession.unitVector(b)
        return Angle.radiansToDegrees(atan2(simd_length(simd_cross(v1, v2)), simd_dot(v1, v2)))
    }

    /// "12° 34′", "34′ 12″" or "12.3″" — the precision an observer wants at
    /// that scale.
    static func formatted(degrees: Double) -> String {
        let totalArcsec = degrees * 3600
        if degrees >= 1 {
            let d = Int(degrees)
            let m = Int(((degrees - Double(d)) * 60).rounded())
            return m == 60 ? "\(d + 1)° 00′" : "\(d)° \(String(format: "%02d", m))′"
        }
        if totalArcsec >= 60 {
            let m = Int(totalArcsec / 60)
            let sec = Int((totalArcsec - Double(m) * 60).rounded())
            return sec == 60 ? "\(m + 1)′ 00″" : "\(m)′ \(String(format: "%02d", sec))″"
        }
        return String(format: "%.1f″", totalArcsec)
    }
}
