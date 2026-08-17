//
//  RenderTypes.swift
//  Astronomy
//
//  GPU-buffer-layout types shared between Swift (buffer construction) and
//  the Metal shaders (Rendering/Shaders/Shaders.metal). Field order/types
//  must stay in sync with the `StarVertex` / `LineVertex` structs defined
//  there — both sides use plain SIMD float types so the memory layout
//  matches without a bridging header.
//

import simd

/// One instance of a point sprite: a star, the Sun, the Moon, or a planet.
struct PointVertex {
    var positionNDC: SIMD2<Float>
    var color: SIMD4<Float>
    var pointSize: Float
    var _padding: Float = 0
}

/// One vertex of a constellation line segment.
struct LineVertex {
    var positionNDC: SIMD2<Float>
    var color: SIMD4<Float>
}
