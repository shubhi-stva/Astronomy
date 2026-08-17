//
//  Shaders.metal
//  Astronomy
//
//  Three render passes, in draw order:
//
//   1. Background pass: one full-screen triangle. The fragment shader inverts
//      the stereographic projection per pixel to recover the sky direction,
//      then paints the horizon/atmosphere gradient (driven by the Sun's
//      altitude) and an analytic Milky Way band in galactic coordinates.
//   2. Line pass: constellation lines as a simple line list.
//   3. Point-sprite pass: stars, their glow haloes, the Sun/Moon/planets and
//      the selection ring. One draw call, `MTLPrimitiveType.point`, with a
//      per-vertex `shape` selector — no per-object draw calls.
//
//  All geometry arrives already projected in normalized device coordinates;
//  the CPU does the spherical trigonometry once per frame.
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Shared structures

struct PointVertexIn {
    float2 positionNDC;
    float4 color;
    float pointSize;
    float shape;
    float param0;
    float param1;
};

struct LineVertexIn {
    float2 positionNDC;
    float4 color;
};

struct PointVaryings {
    float4 position [[position]];
    float4 color;
    float pointSize [[point_size]];
    float shape;
    float param0;
    float param1;
};

struct LineVaryings {
    float4 position [[position]];
    float4 color;
};

struct BackgroundVaryings {
    float4 position [[position]];
    float2 ndc;
};

struct BackgroundUniforms {
    float3x3 cameraToHorizontal;
    float3x3 cameraToGalactic;
    float aspectScaleY;
    float edgeScale;
    float sunAltitudeDegrees;
    float sunAzimuthDegrees;
    float fieldOfViewDegrees;
    float milkyWayStrength;
    float2 _padding;
};

// Shape selectors — keep in sync with `PointSpriteShape` in RenderTypes.swift.
constant float kShapeStarCore     = 0.0;
constant float kShapeGlow         = 1.0;
constant float kShapeDisk         = 2.0;
constant float kShapeMoon         = 3.0;
constant float kShapeSelectionRing = 4.0;

// MARK: - Background pass

vertex BackgroundVaryings backgroundVertexShader(uint vertexID [[vertex_id]]) {
    // Full-screen triangle: three vertices that cover the entire clip space.
    float2 corners[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    BackgroundVaryings out;
    out.position = float4(corners[vertexID], 0.0, 1.0);
    out.ndc = corners[vertexID];
    return out;
}

/// Inverse stereographic projection: viewport NDC -> camera-local direction
/// (x = screen right, y = screen up, z = forward). Mirrors
/// `CoordinateTransformService.stereographicProject` exactly.
static inline float3 directionFromNDC(float2 ndc, constant BackgroundUniforms &u) {
    // Undo the aspect correction, then the field-of-view normalisation.
    float2 square = float2(ndc.x, ndc.y / max(u.aspectScaleY, 1e-4));
    float2 proj = square * u.edgeScale;

    float r = length(proj);
    if (r < 1e-6) {
        return float3(0.0, 0.0, 1.0);
    }
    // Stereographic: a tangent-plane radius r corresponds to an angular
    // distance c = 2 * atan(r / 2) from the projection centre.
    float c = 2.0 * atan(r * 0.5);
    float s = sin(c);
    return float3(proj.x / r * s, proj.y / r * s, cos(c));
}

/// Smoothly interpolated twilight colour ramp, keyed on the Sun's altitude.
/// Boundaries follow the standard definitions: sunrise/sunset -0.833 deg,
/// civil -6 deg, nautical -12 deg, astronomical -18 deg. Night is a deep
/// blue-black, never pure black.
static inline float3 twilightZenithColor(float sunAlt) {
    const float3 day        = float3(0.16, 0.32, 0.62);
    const float3 sunset     = float3(0.10, 0.17, 0.36);
    const float3 civil      = float3(0.045, 0.075, 0.185);
    const float3 nautical   = float3(0.020, 0.036, 0.095);
    const float3 astronomical = float3(0.011, 0.018, 0.048);
    const float3 night      = float3(0.006, 0.010, 0.028);

    if (sunAlt >= 0.0) {
        return mix(sunset, day, saturate(sunAlt / 6.0));
    } else if (sunAlt >= -0.833) {
        return mix(sunset, day, saturate((sunAlt + 0.833) / 0.833) * 0.35);
    } else if (sunAlt >= -6.0) {
        return mix(civil, sunset, saturate((sunAlt + 6.0) / 5.167));
    } else if (sunAlt >= -12.0) {
        return mix(nautical, civil, saturate((sunAlt + 12.0) / 6.0));
    } else if (sunAlt >= -18.0) {
        return mix(astronomical, nautical, saturate((sunAlt + 18.0) / 6.0));
    }
    return mix(night, astronomical, saturate((sunAlt + 24.0) / 6.0));
}

/// Warm colour of the glow hugging the horizon, also keyed on Sun altitude.
static inline float3 horizonGlowColor(float sunAlt) {
    const float3 daylight = float3(0.62, 0.72, 0.88);
    const float3 goldenH  = float3(0.85, 0.50, 0.26);
    const float3 civilH   = float3(0.30, 0.20, 0.24);
    const float3 nightH   = float3(0.055, 0.070, 0.115);

    if (sunAlt >= 4.0) {
        return daylight;
    } else if (sunAlt >= -2.0) {
        return mix(goldenH, daylight, saturate((sunAlt + 2.0) / 6.0));
    } else if (sunAlt >= -10.0) {
        return mix(civilH, goldenH, saturate((sunAlt + 10.0) / 8.0));
    }
    return mix(nightH, civilH, saturate((sunAlt + 18.0) / 8.0));
}

/// Analytic Milky Way. Purely procedural: a Gaussian band around the galactic
/// equator, brightened toward the galactic centre (l ~ 0) and thinned toward
/// the anticentre, with a soft dust lane cut through the middle of the band.
/// See DATA_SOURCES.md — this is a stylised approximation, not survey imagery.
static inline float milkyWayIntensity(float3 galactic) {
    float sinB = clamp(galactic.z, -1.0, 1.0);
    float bDeg = asin(sinB) * (180.0f / M_PI_F);
    float lDeg = atan2(galactic.y, galactic.x) * (180.0f / M_PI_F); // -180..180, 0 = centre

    // Band thickness widens toward the galactic centre (the bulge) and
    // narrows toward the anticentre.
    float towardCenter = 0.5 + 0.5 * cos(lDeg * (M_PI_F / 180.0f));
    float width = mix(6.5, 15.0, towardCenter);

    float band = exp(-0.5 * (bDeg / width) * (bDeg / width));

    // Overall surface brightness falls off away from the galactic centre.
    float longitudeFalloff = mix(0.35, 1.0, pow(towardCenter, 0.8));

    // Central bulge: a broad, brighter blob within ~35 deg of l = 0.
    float bulge = exp(-0.5 * pow(lDeg / 32.0, 2.0)) * exp(-0.5 * pow(bDeg / 13.0, 2.0));

    // The Great Rift: a dark dust lane just off the galactic equator between
    // roughly l = -30 and l = +50 deg.
    float riftLon = exp(-0.5 * pow((lDeg - 10.0) / 34.0, 2.0));
    float riftLat = exp(-0.5 * pow((bDeg - 1.0) / 3.0, 2.0));
    float rift = 1.0 - 0.55 * riftLon * riftLat;

    float intensity = (band * longitudeFalloff * 0.75 + bulge * 0.55) * rift;
    return saturate(intensity);
}

fragment float4 backgroundFragmentShader(
    BackgroundVaryings in [[stage_in]],
    constant BackgroundUniforms &u [[buffer(0)]]
) {
    float3 local = directionFromNDC(in.ndc, u);
    float3 horizontal = normalize(u.cameraToHorizontal * local);
    float altDeg = asin(clamp(horizontal.y, -1.0f, 1.0f)) * (180.0f / M_PI_F);
    // Azimuth measured from north, eastward: X = East, Z = South.
    float azDeg = atan2(horizontal.x, -horizontal.z) * (180.0f / M_PI_F);

    float sunAlt = u.sunAltitudeDegrees;
    float3 zenith = twilightZenithColor(sunAlt);
    float3 glow = horizonGlowColor(sunAlt);

    float3 color;

    if (altDeg >= 0.0) {
        // Above the horizon: exponential brightening toward the horizon line,
        // with an extra lobe centred on the Sun's azimuth so the afterglow
        // sits where the Sun actually went down.
        float horizonFalloff = exp(-altDeg / 11.0);

        float dAz = azDeg - u.sunAzimuthDegrees;
        dAz = dAz - 360.0 * round(dAz / 360.0);
        float sunward = exp(-0.5 * pow(dAz / 55.0, 2.0));
        float sunwardStrength = mix(0.25, 1.0, saturate((sunAlt + 18.0) / 20.0));

        float glowAmount = horizonFalloff * (0.35 + 0.65 * sunward * sunwardStrength);
        color = mix(zenith, glow, saturate(glowAmount));

        // Milky Way, additive, only where the sky is dark enough for it to be
        // physically plausible, and fading out as you zoom in (a telescopic
        // field would not show a diffuse band).
        float darkness = saturate((-sunAlt - 8.0) / 8.0);
        float fovFade = saturate((u.fieldOfViewDegrees - 12.0) / 28.0);
        float horizonFade = saturate(altDeg / 8.0);
        float mw = milkyWayIntensity(u.cameraToGalactic * local);
        float amount = mw * darkness * fovFade * horizonFade * u.milkyWayStrength;
        // Slightly warm-white, as the integrated light of the disk appears.
        color += float3(0.052, 0.050, 0.046) * amount;
    } else {
        // Below the horizon: a distinctly darker, warmer ground tone so the
        // horizon line reads without needing a hard rule drawn across it.
        float depth = saturate(-altDeg / 25.0);
        float3 horizonEdge = mix(zenith, glow, 0.45) * 0.55;
        float3 ground = float3(0.022, 0.019, 0.020);
        color = mix(horizonEdge, ground, smoothstep(0.0, 1.0, depth));
    }

    return float4(color, 1.0);
}

// MARK: - Point sprite pass

vertex PointVaryings starVertexShader(
    uint vertexID [[vertex_id]],
    const device PointVertexIn *vertices [[buffer(0)]]
) {
    PointVertexIn v = vertices[vertexID];
    PointVaryings out;
    out.position = float4(v.positionNDC, 0.0, 1.0);
    out.color = v.color;
    out.pointSize = v.pointSize;
    out.shape = v.shape;
    out.param0 = v.param0;
    out.param1 = v.param1;
    return out;
}

fragment float4 starFragmentShader(
    PointVaryings in [[stage_in]],
    float2 pointCoord [[point_coord]]
) {
    // Sprite-local coordinates in -1...1, +y up.
    float2 p = float2(pointCoord.x, 1.0 - pointCoord.y) * 2.0 - 1.0;
    float dist = length(p);

    float alpha = 0.0;

    if (in.shape == kShapeGlow) {
        // Wide, smooth halo: a Gaussian-ish falloff with no visible edge.
        float f = saturate(1.0 - dist);
        alpha = pow(f, 2.6);
    } else if (in.shape == kShapeDisk) {
        // Solid disk with a soft rim plus a faint outer bloom.
        float core = 1.0 - smoothstep(0.62, 0.86, dist);
        float bloom = pow(saturate(1.0 - dist), 2.2) * 0.35;
        alpha = saturate(core + bloom);
    } else if (in.shape == kShapeMoon) {
        // Lunar disk with a terminator. `param0` is the illuminated fraction
        // k, `param1` the screen-space angle of the bright limb.
        float k = clamp(in.param0, 0.0, 1.0);
        float ca = cos(in.param1);
        float sa = sin(in.param1);
        // Rotate so the bright limb points along +x.
        float2 q = float2(p.x * ca + p.y * sa, -p.x * sa + p.y * ca);

        float diskEdge = 0.86;
        float disk = 1.0 - smoothstep(diskEdge - 0.10, diskEdge + 0.06, dist);

        // Terminator: the projected boundary is the ellipse
        // x = (1 - 2k) * sqrt(1 - y^2) in unit-disk coordinates.
        float yn = clamp(q.y / diskEdge, -1.0, 1.0);
        float terminatorX = (1.0 - 2.0 * k) * sqrt(max(0.0, 1.0 - yn * yn)) * diskEdge;
        float lit = smoothstep(-0.07, 0.07, q.x - terminatorX);

        // Earthshine keeps the dark limb faintly visible instead of a hole.
        float brightness = mix(0.055, 1.0, lit);
        float bloom = pow(saturate(1.0 - dist), 3.0) * 0.28 * (0.3 + 0.7 * k);
        alpha = saturate(disk * brightness + bloom);
    } else if (in.shape == kShapeSelectionRing) {
        // Thin ring with soft inner/outer edges.
        float ring = smoothstep(0.60, 0.72, dist) * (1.0 - smoothstep(0.84, 0.96, dist));
        alpha = ring;
    } else {
        // Star core: crisp, with just enough antialiasing to avoid a hard
        // pixel edge. Medium/faint stars therefore stay as tight dots.
        float f = saturate(1.0 - dist);
        alpha = pow(f, 1.15);
        alpha *= smoothstep(1.02, 0.72, dist);
    }

    alpha *= in.color.a;
    if (alpha <= 0.002) {
        discard_fragment();
    }
    return float4(in.color.rgb, alpha);
}

// MARK: - Line pass

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
