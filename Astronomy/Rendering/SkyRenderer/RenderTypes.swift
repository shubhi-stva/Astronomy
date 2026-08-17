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
}

/// One vertex of a constellation line segment.
struct LineVertex {
    var positionNDC: SIMD2<Float>
    var color: SIMD4<Float>
}
