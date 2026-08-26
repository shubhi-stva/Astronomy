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
import simd

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

    // MARK: - Colour, and the night-legibility guarantee
    //
    //  Everything below mirrors the colour half of the terrain block in
    //  `Shaders.metal`. It exists in Swift for one reason: the skyline has to
    //  be *provably* readable at every time of day, and that is a statement
    //  about colours, which means it has to be testable without a GPU.
    //
    //  The problem it solves: dune colour is derived from the sky (desaturated
    //  toward its own luminance, then darkened per layer). By day that reads
    //  beautifully. At full night the sky is only about (0.008, 0.020, 0.047),
    //  so the furthest dune — the one *at* the skyline, painted at alpha 0.16 —
    //  came out within about 1/255 of the sky behind it. The skyline simply
    //  disappeared.
    //
    //  Two things fix it, and only one of them could:
    //
    //   1. **An absolute floor on how dark each layer is** relative to the sky
    //      (`layerMinimumLuminanceDrop`). Stated in absolute units rather than
    //      as a fraction, so it bites hardest exactly where the multiplicative
    //      rule fails. By day the multiplicative colour is already far darker
    //      than the floor requires, so the floor never binds and the approved
    //      daytime look is untouched, byte for byte.
    //
    //   2. **A rim of sky along the crest of the furthest ridge**
    //      (`skylineRimLift`) — a narrow additive lift in the degree or so
    //      *above* the skyline. This is what actually makes the horizon read at
    //      night, and it is the honest fix: with the furthest layer at alpha
    //      0.16, darkening the dune can move it by at most 16% of the sky's own
    //      brightness, which at night is a fifth of one 8-bit level. No amount
    //      of darkening can win that; a silhouette edge can. It reads as the
    //      last of the skyglow hugging the ridgeline, which is exactly how a
    //      real night skyline is legible.
    //
    //  The rim is *inversely* scaled by sky brightness — full strength at the
    //  darkest sky, gone by daylight — which is what "floored so it survives
    //  the darkest sky" means in practice.
    //
    //  Note on units: the drawable is `bgra8Unorm`, not an sRGB format, so the
    //  numbers the shader writes are already display-encoded. Contrast is
    //  therefore reckoned directly in these units, where a difference of about
    //  0.02 is five 8-bit levels and is comfortably visible on a dark screen.
    //
    //  MIRRORED IN `Shaders.metal`.

    /// How far each layer's colour is pulled toward its own luminance before
    /// being darkened. Dunes are a desaturated relative of the sky, never a
    /// fixed brown. MIRRORED as the 0.62 in `terrainLayerColor`.
    static let desaturation = 0.62

    /// Rec. 709 luminance, the same weights the shader uses.
    static func luminance(_ colour: SIMD3<Double>) -> Double {
        colour.x * 0.2126 + colour.y * 0.7152 + colour.z * 0.0722
    }

    /// Minimum luminance each layer must sit *below* the sky it is painted
    /// over, in absolute display units, far to near. Only binds when the
    /// multiplicative rule fails to produce this much separation, which is to
    /// say only at night.
    ///
    /// MIRRORED IN `Shaders.metal` as `kTerrainMinLuminanceDrop`.
    static let layerMinimumLuminanceDrop: [Double] = [0.050, 0.065, 0.080, 0.095, 0.110]

    /// Additive lift applied to the sky in the narrow band just above the
    /// skyline crest, at full night. Absolute, not proportional: this is the
    /// floor that survives the darkest sky.
    ///
    /// MIRRORED IN `Shaders.metal` as `kSkylineRimLift`.
    static let skylineRimLift = SIMD3<Double>(0.034, 0.040, 0.052)

    /// How far above the crest the rim reaches, in degrees. A rim, not a glow.
    static let skylineRimWidthDegrees = 0.8

    /// The rim fades out as the sky brightens, between these two sky
    /// luminances. Below the first it is at full strength (night); above the
    /// second it is absent entirely (day), so the approved daytime sky is
    /// untouched.
    static let rimFadeStartLuminance = 0.02
    static let rimFadeEndLuminance = 0.25

    /// Colour of one dune layer over the given sky colour.
    ///
    /// MIRRORED IN `Shaders.metal` as `terrainLayerColor`.
    static func layerColor(index: Int, skyColor: SIMD3<Double>) -> SIMD3<Double> {
        let skyLuminance = luminance(skyColor)
        // Mixing toward the luminance is luminance-preserving, so the
        // desaturated colour has exactly `skyLuminance` and the darkness factor
        // is the only thing that darkens it.
        let desaturated = skyColor * (1.0 - desaturation) + SIMD3(repeating: skyLuminance) * desaturation
        var colour = desaturated * layers[index].darkness
        let target = max(0.0, skyLuminance - layerMinimumLuminanceDrop[index])
        let current = luminance(colour)
        if current > target {
            // Scale toward black, which preserves the hue the dune inherited
            // from the sky and only takes brightness away.
            colour *= target / max(current, 1e-6)
        }
        return colour
    }

    /// Strength of the skyline rim at this direction, 0...1 before the
    /// brightness fade: 0 below the crest (where the dunes are), rising across
    /// the crest and decaying over `skylineRimWidthDegrees` above it.
    ///
    /// MIRRORED IN `Shaders.metal` as `skylineRimMask`.
    static func skylineRimMask(altitudeDegrees: Double, azimuthDegrees: Double) -> Double {
        let crest = layerCrestDegrees(index: 0, azimuthDegrees: azimuthDegrees)
        let rise = smoothstep(crest - edgeSoftnessDegrees, crest + edgeSoftnessDegrees, altitudeDegrees)
        let decay = 1.0 - smoothstep(
            crest + edgeSoftnessDegrees,
            crest + edgeSoftnessDegrees + skylineRimWidthDegrees,
            altitudeDegrees
        )
        return rise * decay
    }

    /// The rim's contribution to the sky at this direction.
    ///
    /// MIRRORED IN `Shaders.metal` as `skylineRim`.
    static func skylineRim(
        skyColor: SIMD3<Double>, altitudeDegrees: Double, azimuthDegrees: Double
    ) -> SIMD3<Double> {
        let fade = 1.0 - smoothstep(rimFadeStartLuminance, rimFadeEndLuminance, luminance(skyColor))
        let mask = skylineRimMask(altitudeDegrees: altitudeDegrees, azimuthDegrees: azimuthDegrees)
        return skylineRimLift * (fade * mask)
    }

    /// What the background shader finally paints at this direction, given the
    /// sky colour it computed there: the rim added, then the five dune layers
    /// composited far to near.
    ///
    /// MIRRORED IN `Shaders.metal` — this is the tail of
    /// `backgroundFragmentShader`.
    static func composite(
        skyColor: SIMD3<Double>, altitudeDegrees: Double, azimuthDegrees: Double
    ) -> SIMD3<Double> {
        var colour = skyColor + skylineRim(
            skyColor: skyColor, altitudeDegrees: altitudeDegrees, azimuthDegrees: azimuthDegrees
        )
        for index in layers.indices {
            let alpha = layerOpacity(
                index: index, altitudeDegrees: altitudeDegrees, azimuthDegrees: azimuthDegrees
            )
            guard alpha > 0 else { continue }
            let layerColour = layerColor(index: index, skyColor: skyColor)
            colour = colour * (1.0 - alpha) + layerColour * alpha
        }
        return colour
    }

    /// Same cubic smoothstep Metal's built-in uses, so the two sides match.
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = min(1.0, max(0.0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3.0 - 2.0 * t)
    }
}
