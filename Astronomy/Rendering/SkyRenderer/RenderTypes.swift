//
//  RenderTypes.swift
//  Astronomy
//
//  GPU-buffer-layout types shared between Swift (buffer construction) and
//  the Metal shaders (Rendering/Shaders/Shaders.metal). Field order/types
//  must stay in sync with the matching structs defined there — both sides use
//  plain SIMD float types so the memory layout matches without a bridging
//  header.
//

import simd

/// How a point sprite should be shaded. Encoded as a float in the vertex so a
/// single instanced draw call can cover the whole sky.
enum PointSpriteShape: Float {
    /// Small crisp star core with a tight falloff.
    case starCore = 0
    /// Wide, low-alpha halo drawn *behind* a bright star's core.
    case glow = 1
    /// Solid disk with a soft rim — planets and the Sun.
    case disk = 2
    /// Lunar disk with a terminator: `param0` carries the illuminated
    /// fraction, `param1` the bright-limb angle in radians.
    case moon = 3
    /// Hollow ring used to highlight the selected object.
    case selectionRing = 4
    /// Planetary disk with procedural detail that fades in with zoom.
    /// `param0` = illuminated fraction, `param1` = bright-limb angle (radians),
    /// `param2` = detail level 0...1, `param3` = planet code (see
    /// `StarAppearance.planetShaderCode`).
    case planetDisk = 5
    /// Solar disk: a clear limb plus a bounded bloom. `param2` = detail level.
    case sunDisk = 6
    /// Extended deep-sky object drawn as a soft ellipse inscribed in the
    /// sprite. `param0` = axis ratio (minor/major, 1 for a circle),
    /// `param1` = screen-space angle of the major axis in radians,
    /// `param2` = detail level 0...1, `param3` = type code (see
    /// `StarAppearance.deepSkyShaderCode`).
    case deepSky = 7
    /// Artificial satellite: a small four-pointed cross rather than a dot, so
    /// it reads instantly as "not a star". `param0` carries the illumination
    /// state (0 sunlit, 1 penumbra, 2 umbra) and `param1` the screen-space
    /// direction of travel in radians, which lets the marker carry a short
    /// motion tick pointing the way it is going.
    case satellite = 8
}

/// One instance of a point sprite: a star, its glow, the Sun, the Moon, a
/// planet, or the selection ring.
struct PointVertex {
    var positionNDC: SIMD2<Float>
    var color: SIMD4<Float>
    var pointSize: Float
    /// `PointSpriteShape` raw value.
    var shape: Float
    var param0: Float = 0
    var param1: Float = 0
    var param2: Float = 0
    var param3: Float = 0
}

/// One vertex of a constellation line segment.
struct LineVertex {
    var positionNDC: SIMD2<Float>
    var color: SIMD4<Float>
}
