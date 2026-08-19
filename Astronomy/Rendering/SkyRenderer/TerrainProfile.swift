//
//  TerrainProfile.swift
//  Astronomy
//
//  The "see-through Earth" skyline — layered translucent dunes.
//
//  The app does not cull the sky below the horizon, and as of the layered
//  model it does not *occlude* anything at all. Instead it paints a small
//  stack of overlapping ridgelines at and below the skyline. Each ridge is a
//  translucent haze that tints and dims what is behind it; the furthest sits
//  at the skyline and is lightest, and each nearer one sits lower in the view
//  and is darker and slightly more opaque. That progression is what reads as
//  depth. Stars, the Milky Way and labels all remain visible *through* the
//  terrain — accumulated opacity is capped well below 1 by construction.
//
//  CRITICAL: this profile is implemented TWICE — here in Swift (which decides
//  how much each object is dimmed) and in `Shaders.metal` (which paints the
//  dunes). The two MUST agree exactly, or objects will dim against a skyline
//  that is not where it is drawn. The Metal copy lives in the
//  "TERRAIN PROFILE — mirror of TerrainProfile.swift" block; any edit here must
//  be mirrored there and vice versa. The unit tests pin the Swift values at
//  fixed azimuths, for every layer, so an unmirrored edit is caught.
//

import Foundation

enum TerrainProfile {

    // MARK: - Layer description

    /// One ridgeline. `baseOffsetDegrees` is where the layer's mean crest sits
    /// relative to the true horizon (0 for the furthest, progressively more
    /// negative for nearer ones); `alpha` is its own opacity; `darkness` is the
    /// factor its colour is multiplied by after being desaturated toward grey,
    /// so nearer layers are darker.
    struct Layer {
        let amplitude1: Double
        let amplitude2: Double
        let amplitude3: Double
        let amplitude4: Double
        let phase1: Double
        let phase2: Double
        let phase3: Double
        let phase4: Double
        let baseOffsetDegrees: Double
        let alpha: Double
        let darkness: Double

        /// The profile can never leave `[-maxAmplitude, +maxAmplitude]` of its
        /// own base offset.
        var maxAmplitude: Double { amplitude1 + amplitude2 + amplitude3 + amplitude4 }
    }

    /// Five ridgelines, ordered FAR to NEAR — index 0 sits at the skyline and
    /// is the lightest and least opaque; index 4 is the nearest, lowest,
    /// darkest and most opaque. Compositing order in the shader is the same
    /// order, so nearer layers paint over further ones.
    ///
    /// Every layer uses the same *integer* frequencies (1, 2, 3, 5) in azimuth,
    /// which is what guarantees exact periodicity over 0-360 degrees and hence
    /// no seam at due north. Only amplitudes, phases and offsets differ, which
    /// is enough to make the ridges read as unrelated landforms.
    ///
    /// Layer 0's constants are deliberately unchanged from the original single
    /// skyline, so `skylineAltitudeDegrees` still means exactly what it always
    /// did and the cardinal markers still sit where they always sat.
    ///
    /// MIRRORED IN `Shaders.metal` as `kTerrainLayers`.
    static let layers: [Layer] = [
        Layer(amplitude1: 0.90, amplitude2: 0.60, amplitude3: 0.40, amplitude4: 0.25,
              phase1: 37.0, phase2: 113.0, phase3: 211.0, phase4: 67.0,
              baseOffsetDegrees: 0.0,  alpha: 0.16, darkness: 0.55),
        Layer(amplitude1: 1.10, amplitude2: 0.70, amplitude3: 0.35, amplitude4: 0.20,
              phase1: 151.0, phase2: 19.0, phase3: 263.0, phase4: 97.0,
              baseOffsetDegrees: -1.8, alpha: 0.20, darkness: 0.42),
        Layer(amplitude1: 1.30, amplitude2: 0.80, amplitude3: 0.45, amplitude4: 0.22,
              phase1: 289.0, phase2: 71.0, phase3: 143.0, phase4: 17.0,
              baseOffsetDegrees: -4.0, alpha: 0.24, darkness: 0.31),
        Layer(amplitude1: 1.50, amplitude2: 0.95, amplitude3: 0.50, amplitude4: 0.28,
              phase1: 73.0, phase2: 241.0, phase3: 29.0, phase4: 199.0,
              baseOffsetDegrees: -7.0, alpha: 0.28, darkness: 0.21),
        Layer(amplitude1: 1.70, amplitude2: 1.05, amplitude3: 0.55, amplitude4: 0.30,
              phase1: 203.0, phase2: 131.0, phase3: 83.0, phase4: 251.0,
              baseOffsetDegrees: -11.0, alpha: 0.32, darkness: 0.12),
    ]

    /// Softening applied to each ridgeline's edge, in degrees. Deliberately a
    /// fraction of a degree: enough to antialias the crest, never enough to
    /// make it read as blurry. These edges are the visual anchor of the effect.
    static let edgeSoftnessDegrees = 0.25

    /// How strongly accumulated terrain coverage dims a celestial object.
    ///
    /// Objects are never rejected any more; their visibility is multiplied by
    /// `1 - coverage * coverageDimmingFactor`. There is exactly one story: the
    /// further down you look, the more dune haze is between you and the sky,
    /// and that is *all* that dims it.
    ///
    /// Lowered from 0.72 so the floor rises from about 0.46 to about 0.66. The
    /// dunes are meant to *veil* the set sky, not swallow it — the whole point
    /// of the see-through view is reading what is below the horizon, and stars
    /// there were fading into the haze rather than showing through it.
    static let coverageDimmingFactor = 0.45

    // MARK: - The profile itself

    /// Undulation of one layer about its own base offset, in degrees.
    ///
    /// Four sinusoids at *integer* frequencies (1, 2, 3, 5) in azimuth, so the
    /// profile is exactly periodic over 0-360 degrees and there is no seam at
    /// due north. Each sinusoid has zero mean over a full turn, so the layer's
    /// mean crest sits exactly at its base offset.
    ///
    /// MIRRORED IN `Shaders.metal` as `terrainLayerUndulationDegrees`.
    static func layerUndulationDegrees(layer: Layer, azimuthDegrees: Double) -> Double {
        let d = Double.pi / 180.0
        let a = azimuthDegrees * d
        return layer.amplitude1 * sin(a * 1.0 + layer.phase1 * d)
             + layer.amplitude2 * sin(a * 2.0 + layer.phase2 * d)
             + layer.amplitude3 * sin(a * 3.0 + layer.phase3 * d)
             + layer.amplitude4 * sin(a * 5.0 + layer.phase4 * d)
    }

    /// Crest altitude of one layer at the given azimuth: base offset plus
    /// undulation. A pixel is covered by the layer when its altitude is below
    /// this, with a soft edge of `edgeSoftnessDegrees`.
    ///
    /// MIRRORED IN `Shaders.metal` as `terrainLayerCrestDegrees`.
    static func layerCrestDegrees(index: Int, azimuthDegrees: Double) -> Double {
        let layer = layers[index]
        return layer.baseOffsetDegrees + layerUndulationDegrees(layer: layer, azimuthDegrees: azimuthDegrees)
    }

    /// Altitude of the skyline — the crest of the furthest layer — in degrees.
    /// This is what the cardinal markers are pinned just above, and what the
    /// unit tests pin at fixed azimuths.
    static func skylineAltitudeDegrees(azimuthDegrees: Double) -> Double {
        layerCrestDegrees(index: 0, azimuthDegrees: azimuthDegrees)
    }

    /// Total undulation half-range of the furthest (skyline) layer.
    static var maxAmplitude: Double { layers[0].maxAmplitude }

    // MARK: - Coverage

    /// How opaque one layer is at this direction: its own alpha, faded across
    /// the soft crest edge. 0 well above the crest, `layer.alpha` well below.
    ///
    /// MIRRORED IN `Shaders.metal` as `terrainLayerOpacity`.
    static func layerOpacity(index: Int, altitudeDegrees: Double, azimuthDegrees: Double) -> Double {
        let crest = layerCrestDegrees(index: index, azimuthDegrees: azimuthDegrees)
        let mask = 1.0 - smoothstep(crest - edgeSoftnessDegrees, crest + edgeSoftnessDegrees, altitudeDegrees)
        return layers[index].alpha * mask
    }

    /// Accumulated terrain opacity in 0...1 for this direction, composited far
    /// to near exactly as the shader does it: `1 - prod(1 - alpha_i)`.
    ///
    /// Because each layer's alpha is well under 1 and there are only five of
    /// them, this can never reach 1 — `maxCoverage` is the ceiling, and it is
    /// the formal statement of "nothing is fully hidden".
    ///
    /// MIRRORED IN `Shaders.metal` as `terrainCoverage`.
    static func coverage(altitudeDegrees: Double, azimuthDegrees: Double) -> Double {
        var transmittance = 1.0
        for index in layers.indices {
            transmittance *= 1.0 - layerOpacity(
                index: index, altitudeDegrees: altitudeDegrees, azimuthDegrees: azimuthDegrees
            )
        }
        return 1.0 - transmittance
    }

    /// The largest coverage the stack can produce: every layer at full alpha.
    static var maxCoverage: Double {
        1.0 - layers.reduce(1.0) { $0 * (1.0 - $1.alpha) }
    }

    /// The smallest visibility multiplier terrain can ever impose. Kept
    /// comfortably above zero on purpose: even the nearest, darkest dune only
    /// dims a star, it never removes it.
    static var minimumVisibility: Double { 1.0 - maxCoverage * coverageDimmingFactor }

    /// Brightness multiplier for an object at this altitude/azimuth.
    ///
    /// 1 above every crest, falling smoothly as more dune layers accumulate in
    /// front of the direction, bottoming out at `minimumVisibility`. This is
    /// the single dimming system: there is no separate below-horizon term any
    /// more.
    ///
    /// MIRRORED IN `Shaders.metal` as `terrainDimming`.
    static func dimming(altitudeDegrees: Double, azimuthDegrees: Double) -> Double {
        1.0 - coverage(altitudeDegrees: altitudeDegrees, azimuthDegrees: azimuthDegrees) * coverageDimmingFactor
    }

    /// Same cubic smoothstep Metal's built-in uses, so the two sides match.
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = min(1.0, max(0.0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3.0 - 2.0 * t)
    }
}
