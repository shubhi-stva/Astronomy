//
//  Shaders.metal
//  Astronomy
//
//  Two render passes, both driven from small per-frame vertex buffers built
//  on the CPU each frame from projected sky coordinates:
//   1. Point-sprite pass: stars + Sun/Moon/planets as glowing circular
//      sprites, sized/colored by magnitude and color index. One draw call,
//      instanced via MTLPrimitiveType.point (no per-star draw calls).
//   2. Line pass: constellation lines as a simple line list.
//

#include <metal_stdlib>
using namespace metal;

struct PointVertexIn {
    float2 positionNDC;
    float4 color;
    float pointSize;
    float _padding;
};

struct LineVertexIn {
    float2 positionNDC;
    float4 color;
};

struct PointVaryings {
    float4 position [[position]];
    float4 color;
    float pointSize [[point_size]];
};

struct LineVaryings {
    float4 position [[position]];
    float4 color;
};

vertex PointVaryings starVertexShader(
    uint vertexID [[vertex_id]],
    const device PointVertexIn *vertices [[buffer(0)]]
) {
    PointVertexIn v = vertices[vertexID];
    PointVaryings out;
    out.position = float4(v.positionNDC, 0.0, 1.0);
    out.color = v.color;
    out.pointSize = v.pointSize;
    return out;
}

fragment float4 starFragmentShader(
    PointVaryings in [[stage_in]],
    float2 pointCoord [[point_coord]]
) {
    // Soft circular glow: solid-ish core fading to transparent edge.
    float2 centered = pointCoord - float2(0.5, 0.5);
    float dist = length(centered) * 2.0; // 0 at center, 1 at edge
    float alpha = smoothstep(1.0, 0.0, dist);
    alpha = pow(alpha, 1.4);
    if (alpha <= 0.001) {
        discard_fragment();
    }
    return float4(in.color.rgb, in.color.a * alpha);
}

vertex LineVaryings lineVertexShader(
    uint vertexID [[vertex_id]],
    const device LineVertexIn *vertices [[buffer(0)]]
) {
    LineVertexIn v = vertices[vertexID];
    LineVaryings out;
    out.position = float4(v.positionNDC, 0.0, 1.0);
    out.color = v.color;
    return out;
}

fragment float4 lineFragmentShader(LineVaryings in [[stage_in]]) {
    return in.color;
}
