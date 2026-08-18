//
//  TerrainProfile.swift
//  Astronomy
//
//  The "see-through Earth" skyline.
//
//  The app does not cull the sky below the horizon. Instead it draws an opaque
//  near-black band of rolling hills at the skyline, and keeps rendering the sky
//  underneath it — the part of the celestial sphere genuinely beneath the
//  observer's feet, in its true position, merely dimmed. Nothing about where an
//  object is computed to be changes; this is purely an occlusion/visibility
//  model.
//
//  CRITICAL: this profile is implemented TWICE — here in Swift (which decides
//  which objects are hidden) and in `Shaders.metal` (which paints the band).
//  The two MUST agree exactly, or objects will clip against a skyline that is
//  not where it is drawn. The Metal copy lives in the
//  "TERRAIN PROFILE — mirror of TerrainProfile.swift" block; any edit here must
//  be mirrored there and vice versa. The unit tests pin the Swift values at
//  fixed azimuths so an unmirrored edit is caught.
//

import Foundation

enum TerrainProfile {

    // MARK: - Profile shape

    /// Amplitudes, in degrees. They sum to `2.15`, so the skyline undulates
    /// within +/- 2.15 degrees of altitude 0 — gentle, distant rolling hills,
    /// not mountains.
    static let amplitude1 = 0.90
    static let amplitude2 = 0.60
    static let amplitude3 = 0.40
    static let amplitude4 = 0.25

    /// Hand-picked phases, in degrees. Nothing derived — they were chosen so
    /// the sum reads as non-repetitive over a full turn.
    static let phase1 = 37.0
    static let phase2 = 113.0
    static let phase3 = 211.0
    static let phase4 = 67.0

    /// Total undulation half-range: the profile can never leave
    /// `[-maxAmplitude, +maxAmplitude]`.
    static var maxAmplitude: Double { amplitude1 + amplitude2 + amplitude3 + amplitude4 }

    /// Vertical thickness of the opaque silhouette band, in degrees, measured
    /// downward from the skyline. Deep enough that panning down shows solid
    /// ground before the sky resumes.
    static let bandThicknessDegrees = 12.0

    /// How much the sub-horizon sky is dimmed relative to the sky above. Kept
    /// high on purpose: the whole point of the feature is that the hidden half
    /// of the sky stays rich and legible.
    static let belowHorizonDimming = 0.55

    /// Degrees over which the dimming eases in, starting at the bottom edge of
    /// the band, so there is no hard line where the dimming begins.
    static let dimmingEaseDegrees = 2.5

    /// Softening applied to the top edge of the band, in degrees. Deliberately
    /// a fraction of a degree: just enough to antialias the skyline, never
    /// enough to make it read as blurry. This edge is the visual anchor of the
    /// whole effect.
    static let edgeSoftnessDegrees = 0.10

    // MARK: - The profile itself

    /// Altitude of the skyline, in degrees, at the given azimuth.
    ///
    /// Four sinusoids at *integer* frequencies (1, 2, 3, 5) in azimuth, so the
    /// profile is exactly periodic over 0-360 degrees and there is no seam at
    /// due north. Each sinusoid has zero mean over a full turn, so the mean
    /// skyline already sits at altitude 0 and no constant offset is needed.
    ///
    /// MIRRORED IN `Shaders.metal` as `terrainSkylineDegrees`.
    static func skylineAltitudeDegrees(azimuthDegrees: Double) -> Double {
        let d = Double.pi / 180.0
        let a = azimuthDegrees * d
        return amplitude1 * sin(a * 1.0 + phase1 * d)
             + amplitude2 * sin(a * 2.0 + phase2 * d)
             + amplitude3 * sin(a * 3.0 + phase3 * d)
             + amplitude4 * sin(a * 5.0 + phase4 * d)
    }

    /// Altitude of the bottom edge of the opaque band at the given azimuth.
    static func bandBottomDegrees(azimuthDegrees: Double) -> Double {
        skylineAltitudeDegrees(azimuthDegrees: azimuthDegrees) - bandThicknessDegrees
    }

    // MARK: - Occlusion

    /// Is a point at this altitude/azimuth hidden behind the terrain?
    ///
    /// True **only** inside the band. Anything above the skyline is visible as
    /// it always was; anything below the band is visible again, because you are
    /// looking through the Earth.
    ///
    /// MIRRORED IN `Shaders.metal` (zone 2 of `backgroundFragmentShader`).
    static func isOccluded(altitudeDegrees: Double, azimuthDegrees: Double) -> Bool {
        let skyline = skylineAltitudeDegrees(azimuthDegrees: azimuthDegrees)
        return altitudeDegrees <= skyline && altitudeDegrees > skyline - bandThicknessDegrees
    }

    /// Brightness multiplier for an object at this altitude/azimuth: 1 above
    /// the skyline, easing down to `belowHorizonDimming` a couple of degrees
    /// below the band. Inside the band the value is irrelevant (the object is
    /// occluded), but it is defined and continuous there anyway.
    ///
    /// MIRRORED IN `Shaders.metal` as `terrainDimming`.
    static func dimming(altitudeDegrees: Double, azimuthDegrees: Double) -> Double {
        let skyline = skylineAltitudeDegrees(azimuthDegrees: azimuthDegrees)
        if altitudeDegrees > skyline { return 1.0 }
        let bottom = skyline - bandThicknessDegrees
        let t = smoothstep(0.0, dimmingEaseDegrees, bottom - altitudeDegrees)
        return 1.0 + (belowHorizonDimming - 1.0) * t
    }

    /// Same cubic smoothstep Metal's built-in uses, so the two sides match.
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = min(1.0, max(0.0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3.0 - 2.0 * t)
    }
}
