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
    float param2;
    float param3;
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
    float param2;
    float param3;
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
    // Unit vector toward the Sun in the horizontal frame (X = East,
    // Y = Zenith, Z = South). Scalars, not a float3, so the layout matches
    // `SkyBackgroundUniforms` in Swift without alignment padding.
    float sunDirectionX;
    float sunDirectionY;
    float sunDirectionZ;
    float milkyWayTextureStrength;
    float _padding1;
    float _padding2;
};

// Shape selectors — keep in sync with `PointSpriteShape` in RenderTypes.swift.
constant float kShapeStarCore     = 0.0;
constant float kShapeGlow         = 1.0;
constant float kShapeDisk         = 2.0;
constant float kShapeMoon         = 3.0;
constant float kShapeSelectionRing = 4.0;
constant float kShapePlanetDisk   = 5.0;
constant float kShapeSunDisk      = 6.0;
constant float kShapeDeepSky      = 7.0;

// Deep-sky type codes — keep in sync with `StarAppearance.deepSkyShaderCode`.
constant int kDeepSkyGalaxy    = 0;
constant int kDeepSkyGlobular  = 1;
constant int kDeepSkyOpen      = 2;
constant int kDeepSkyNebula    = 3;
constant int kDeepSkyPlanetary = 4;
constant int kDeepSkyRemnant   = 5;

// Planet codes — keep in sync with `StarAppearance.planetShaderCode`.
constant int kPlanetMercury = 0;
constant int kPlanetVenus   = 1;
constant int kPlanetMars    = 2;
constant int kPlanetJupiter = 3;
constant int kPlanetSaturn  = 4;
constant int kPlanetUranus  = 5;
constant int kPlanetNeptune = 6;

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

// ---------------------------------------------------------------------------
//  SKY LIGHTING MODEL — an analytic approximation, NOT physically based
//  rendering.
//
//  What it borrows, and from where:
//
//   * The *shape* of the daytime sky comes from the same two ingredients that
//     drive the Preetham et al. (1999) and Hosek-Wilkie (2012) analytic
//     skylight models: an angular term built from scattering phase functions,
//     multiplied by a term that grows with the optical path length through the
//     atmosphere.
//   * Angular term: the Rayleigh phase function `(3/4)(1 + cos^2 gamma)` for
//     molecular scattering (this is why the sky is deepest ~90 deg from the
//     Sun and brightens both toward the Sun and toward the antisolar point),
//     plus a forward-scattering Henyey-Greenstein lobe (Henyey & Greenstein
//     1941) with g = 0.76 standing in for aerosol/Mie scattering (this is the
//     broad soft brightening around the Sun, and the golden-hour glow).
//     `gamma` is the TRUE angular distance from the Sun, from
//     dot(skyDirection, sunDirection) — not an azimuth difference.
//   * Optical path term: relative air mass from Kasten & Young (1989),
//         X(h) = 1 / (sin h + 0.50572 * (h_deg + 6.07995)^-1.6364)
//     which runs from 1.0 at the zenith to about 38 at the horizon. A longer
//     path means more scattering, so the horizon is lighter, less saturated
//     and slightly warmer. (An older, similar published fit is Young & Irvine
//     1967, `1/(sin h + 0.15 (h_deg + 3.885)^-1.253)`; Kasten-Young is the
//     more accurate of the two and is what is used here.)
//
//  What it deliberately OMITS — do not mistake this for a radiative transfer
//  solution:
//   * No aerosol turbidity parameter (Preetham's T). Aerosol load is a single
//     baked-in constant.
//   * No ozone absorption (which is what actually makes deep twilight blue).
//   * No multiple scattering. Only a single-scattering-shaped angular profile;
//     the twilight colours below the horizon-crossing are an artistic ramp,
//     not an integration along Earth-shadow geometry.
//   * No per-wavelength spectral integration and no Rayleigh 1/lambda^4
//     weighting — colour is carried by an interpolated RGB ramp keyed on Sun
//     altitude, so the phase functions modulate brightness and saturation,
//     not hue.
//   * No sun/sky illuminance calibration, no tone mapping, no exposure model.
//   * No clouds, no terrain shadowing, no refraction of the solar disk.
//  See DATA_SOURCES.md for the same list in prose.
// ---------------------------------------------------------------------------

/// One segment of a colour ramp. `smoothstep` clamps outside [x0, x1] and has
/// zero derivative at both ends, so chaining segments that share endpoint
/// colours is continuous *and* has no visible crease at an anchor.
static inline float3 rampSegment(float x, float x0, float x1, float3 c0, float3 c1) {
    return mix(c0, c1, smoothstep(x0, x1, x));
}

/// Zenith sky colour, keyed on the Sun's altitude. Anchors sit on the standard
/// twilight boundaries — sunset -0.833 deg, civil -6, nautical -12,
/// astronomical -18 — so each band ends where it should, but every transition
/// is a smoothstep between neighbouring anchors, with no branch able to
/// disagree with its neighbour at the boundary. Night is a deep blue-black,
/// never pure black.
static inline float3 twilightZenithColor(float a) {
    const float3 cHigh   = float3(0.105, 0.255, 0.620);  // +60 deg: rich deep blue
    const float3 cMid    = float3(0.140, 0.305, 0.640);  // +20 deg
    const float3 cLow    = float3(0.170, 0.310, 0.575);  //  +5 deg
    const float3 cSunset = float3(0.115, 0.190, 0.400);  //   0 deg
    const float3 cDusk   = float3(0.085, 0.135, 0.300);  // -0.833 deg
    const float3 cCivil  = float3(0.045, 0.075, 0.185);  //  -6 deg
    const float3 cNaut   = float3(0.020, 0.036, 0.095);  // -12 deg
    const float3 cAstro  = float3(0.011, 0.018, 0.048);  // -18 deg
    const float3 cNight  = float3(0.006, 0.010, 0.028);  // -25 deg and below

    if (a <= -25.0)  { return cNight; }
    if (a <= -18.0)  { return rampSegment(a, -25.0, -18.0, cNight, cAstro); }
    if (a <= -12.0)  { return rampSegment(a, -18.0, -12.0, cAstro, cNaut); }
    if (a <=  -6.0)  { return rampSegment(a, -12.0,  -6.0, cNaut,  cCivil); }
    if (a <=  -0.833){ return rampSegment(a,  -6.0,  -0.833, cCivil, cDusk); }
    if (a <=   0.0)  { return rampSegment(a,  -0.833, 0.0, cDusk,  cSunset); }
    if (a <=   5.0)  { return rampSegment(a,   0.0,   5.0, cSunset, cLow); }
    if (a <=  20.0)  { return rampSegment(a,   5.0,  20.0, cLow,   cMid); }
    return rampSegment(a, 20.0, 60.0, cMid, cHigh);
}

/// Colour the sky tends toward along a long horizon path — pale blue-white by
/// day, gold at sunset, dropping to a dim slate at night. Same continuous
/// anchor-ramp construction as above.
static inline float3 horizonGlowColor(float a) {
    const float3 hHigh   = float3(0.600, 0.710, 0.880);  // +20 deg: pale haze
    const float3 hLow    = float3(0.740, 0.760, 0.840);  //  +6 deg
    const float3 hGolden = float3(0.900, 0.550, 0.280);  //   0 deg: golden hour
    const float3 hDeep   = float3(0.700, 0.360, 0.250);  //  -4 deg
    const float3 hCivil  = float3(0.300, 0.200, 0.240);  // -10 deg
    const float3 hNight  = float3(0.055, 0.070, 0.115);  // -18 deg and below

    if (a <= -18.0) { return hNight; }
    if (a <= -10.0) { return rampSegment(a, -18.0, -10.0, hNight,  hCivil); }
    if (a <=  -4.0) { return rampSegment(a, -10.0,  -4.0, hCivil,  hDeep); }
    if (a <=   0.0) { return rampSegment(a,  -4.0,   0.0, hDeep,   hGolden); }
    if (a <=   6.0) { return rampSegment(a,   0.0,   6.0, hGolden, hLow); }
    return rampSegment(a, 6.0, 20.0, hLow, hHigh);
}

/// Relative optical air mass, Kasten & Young (1989), "Revised optical air mass
/// tables and approximation formula", Applied Optics 28, 4735. 1.0 at the
/// zenith, ~38 at the true horizon. Extended smoothly a little below the
/// horizon so the ground blend has no discontinuity at alt = 0.
static inline float relativeAirMass(float altDeg) {
    float h = max(altDeg, -1.0);
    float sinH = sin(h * (M_PI_F / 180.0f));
    float denom = sinH + 0.50572 * pow(max(h + 6.07995, 1e-3), -1.6364);
    return clamp(1.0f / max(denom, 1e-3f), 1.0f, 40.0f);
}

/// Henyey-Greenstein phase function (Henyey & Greenstein 1941), the standard
/// cheap stand-in for the strongly forward-peaked Mie phase function.
static inline float henyeyGreenstein(float cosTheta, float g) {
    float g2 = g * g;
    float denom = 1.0 + g2 - 2.0 * g * cosTheta;
    return (1.0 - g2) / (4.0 * M_PI_F * pow(max(denom, 1e-4f), 1.5f));
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

/// Equirectangular lookup into the all-sky panorama, in galactic coordinates.
///
/// The image is 2:1, centred on the galactic centre, with galactic longitude
/// increasing to the *left* — verified against the catalogued positions of the
/// Large and Small Magellanic Clouds, which land on the two obvious blobs in
/// the lower right only under this sign convention. Latitude runs from
/// b = +90 at the top edge to b = -90 at the bottom.
static inline float3 milkyWayPanorama(
    float3 galactic,
    texture2d<float> panorama,
    sampler panoramaSampler
) {
    float l = atan2(galactic.y, galactic.x);                  // -pi..pi, 0 = centre
    float b = asin(clamp(galactic.z, -1.0f, 1.0f));           // -pi/2..pi/2
    float2 uv = float2(0.5 - l / (2.0 * M_PI_F), 0.5 - b / M_PI_F);
    return panorama.sample(panoramaSampler, uv).rgb;
}

fragment float4 backgroundFragmentShader(
    BackgroundVaryings in [[stage_in]],
    constant BackgroundUniforms &u [[buffer(0)]],
    texture2d<float> milkyWayPanoramaTexture [[texture(0)]],
    sampler milkyWaySampler [[sampler(0)]]
) {
    float3 local = directionFromNDC(in.ndc, u);
    float3 horizontal = normalize(u.cameraToHorizontal * local);
    float altDeg = asin(clamp(horizontal.y, -1.0f, 1.0f)) * (180.0f / M_PI_F);

    float sunAlt = u.sunAltitudeDegrees;
    float3 zenith = twilightZenithColor(sunAlt);
    float3 glow = horizonGlowColor(sunAlt);

    // --- Scattering geometry (see the model comment block above) ------------
    float3 sunDir = float3(u.sunDirectionX, u.sunDirectionY, u.sunDirectionZ);
    float sunLen = length(sunDir);
    sunDir = sunLen > 1e-5 ? sunDir / sunLen : float3(0.0, -1.0, 0.0);
    // cos of the true angular distance gamma between this pixel and the Sun.
    float cosGamma = clamp(dot(horizontal, sunDir), -1.0f, 1.0f);

    // Rayleigh phase, normalised to 0...1 over its 0.5...1.0 range: 1 straight
    // at and straight away from the Sun, 0 at 90 deg elongation, which is the
    // band of deepest, most saturated blue.
    float rayleigh = saturate((1.0 + cosGamma * cosGamma) * 0.5);

    // Mie: a sharp forward lobe, normalised against its own peak, softened by
    // a deliberately broad cos-power lobe so the result reads as a wide gentle
    // brightening rather than a hard disk of glow around the Sun.
    float mieNorm = henyeyGreenstein(cosGamma, 0.76) / henyeyGreenstein(1.0, 0.76);
    float broadLobe = pow(saturate(0.5 + 0.5 * cosGamma), 4.0);
    float sunward = saturate(0.55 * mieNorm + 0.75 * broadLobe);

    // Optical path: 0 at the zenith, approaching 1 at the horizon.
    float airMass = relativeAirMass(altDeg);
    float pathAmount = 1.0 - exp(-0.20 * (airMass - 1.0));

    // How "daylit" the atmosphere is; gates the pale washed-out look so it
    // does not survive into twilight, where the warm ramp should take over.
    float dayFactor = saturate((sunAlt + 2.0) / 8.0);

    float3 color;

    if (altDeg >= 0.0) {
        // Horizon lightening: more air to look through means more scattered
        // light reaches the eye, and it does so preferentially near the Sun.
        float horizonAmount = pathAmount * (0.42 + 0.58 * sunward);
        color = mix(zenith, glow, saturate(horizonAmount));

        // Rayleigh angular modulation: a few percent, enough to read as a
        // deeper blue at right angles to the Sun without looking banded.
        color *= mix(0.88, 1.06, rayleigh);

        // Desaturate and brighten toward the Sun: near the Sun the sky is
        // washed out and low-contrast, far from it deep and saturated.
        float pale = sunward * dayFactor;
        float lum = dot(color, float3(0.2126, 0.7152, 0.0722));
        float3 washed = saturate(mix(color, float3(lum), 0.75) * 1.45 + float3(0.060, 0.055, 0.050));
        color = mix(color, washed, saturate(0.60 * pale));

        // Golden hour: a warm additive term that peaks with the Sun near the
        // horizon (Gaussian in Sun altitude, sigma 7 deg), concentrated both
        // toward the Sun's direction and toward the horizon via the path term.
        float golden = exp(-0.5 * pow(sunAlt / 7.0, 2.0));
        color += float3(0.42, 0.20, 0.07) * golden * sunward * pow(pathAmount, 1.5);

        // A last touch of warmth in the bottom few degrees, where the longest
        // paths preferentially scatter the blue out of the beam.
        float veryLow = 1.0 - smoothstep(0.0, 7.0, altDeg);
        color = mix(color, color * float3(1.07, 1.00, 0.94), veryLow * 0.6 * dayFactor);

        // Milky Way, additive, only where the sky is dark enough for it to be
        // physically plausible, and fading out as you zoom in (a telescopic
        // field would not show a diffuse band).
        float darkness = saturate((-sunAlt - 8.0) / 8.0);
        float fovFade = saturate((u.fieldOfViewDegrees - 12.0) / 28.0);
        float horizonFade = saturate(altDeg / 8.0);
        float3 galactic = u.cameraToGalactic * local;
        float envelope = darkness * fovFade * horizonFade * u.milkyWayStrength;

        if (u.milkyWayTextureStrength > 0.5) {
            // Real photographic structure — dust lanes, the Great Rift, the
            // bulge — from the bundled all-sky panorama. Added, never
            // replacing the sky: the atmosphere model underneath still owns
            // the colour of the sky itself.
            float3 photo = milkyWayPanorama(galactic, milkyWayPanoramaTexture, milkyWaySampler);
            // The panorama is a long-exposure image and is far brighter than a
            // dark-adapted eye sees, so it is scaled down hard and pulled most
            // of the way toward neutral: the point is the *structure*, not the
            // saturation. A gamma above 1 deepens the dark lanes at the same
            // time, which is what makes the Rift read.
            float3 shaped = pow(saturate(photo), float3(1.35));
            float lum = dot(shaped, float3(0.2126, 0.7152, 0.0722));
            shaped = mix(float3(lum), shaped, 0.55);
            color += shaped * 0.30 * envelope;
        } else {
            // No texture available: the analytic band, unchanged.
            float mw = milkyWayIntensity(galactic);
            // Slightly warm-white, as the integrated light of the disk appears.
            color += float3(0.052, 0.050, 0.046) * (mw * envelope);
        }
    } else {
        // Below the horizon: a distinctly darker, warmer ground tone so the
        // horizon line reads without needing a hard rule drawn across it.
        float depth = saturate(-altDeg / 25.0);
        float3 horizonEdge = mix(zenith, glow, 0.45) * 0.55;
        float3 ground = float3(0.022, 0.019, 0.020);
        color = mix(horizonEdge, ground, smoothstep(0.0, 1.0, depth));
    }

    // --- Field-of-view darkening ---------------------------------------------
    // As you zoom in, the whole background is dimmed slightly. This is an
    // aesthetic and legibility choice, not physics: a telescope pointed at a
    // patch of daylight sky does not see a darker sky, and the surface
    // brightness of the background is genuinely invariant under magnification.
    // What it buys is contrast. At a narrow field the star field is at its
    // deepest (the limiting magnitude reaches 9), and those faintest stars
    // need somewhere dark to sit; it also matches the felt experience of
    // shutting out the surrounding scattered-light context as you put your eye
    // to an eyepiece.
    //
    // Kept mild and continuous so it cannot fight the twilight model: full
    // strength above 60 degrees, easing to 0.82 by 6 degrees, smoothstepped in
    // log(FOV) so it tracks the same pinch feel as the magnitude limit. It is
    // a multiplier, so a bright daylight sky stays a bright daylight sky —
    // just a shade deeper.
    float logFov = log(max(u.fieldOfViewDegrees, 0.5));
    float zoomIn = 1.0 - smoothstep(log(6.0), log(60.0), logFov);
    color *= mix(1.0, 0.82, zoomIn);

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
    out.param2 = v.param2;
    out.param3 = v.param3;
    return out;
}

/// Shared terminator test for a phased body. Returns 1 on the sunlit side of
/// the projected terminator and 0 on the night side, with a soft edge.
/// `q` is sprite-local, already rotated so the bright limb points along +x;
/// `k` is the illuminated fraction. The terminator is the ellipse
/// `x = (1 - 2k) * sqrt(1 - y^2)` in unit-disk coordinates — the projection of
/// the great circle separating day from night.
static inline float terminatorLit(float2 q, float k, float diskEdge, float softness) {
    float yn = clamp(q.y / diskEdge, -1.0, 1.0);
    float terminatorX = (1.0 - 2.0 * k) * sqrt(max(0.0, 1.0 - yn * yn)) * diskEdge;
    return smoothstep(-softness, softness, q.x - terminatorX);
}

fragment float4 starFragmentShader(
    PointVaryings in [[stage_in]],
    float2 pointCoord [[point_coord]]
) {
    // Sprite-local coordinates in -1...1, +y up.
    float2 p = float2(pointCoord.x, 1.0 - pointCoord.y) * 2.0 - 1.0;
    float dist = length(p);

    float alpha = 0.0;
    float3 rgb = in.color.rgb;

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
        float lit = terminatorLit(q, k, diskEdge, 0.07);

        // Earthshine keeps the dark limb faintly visible instead of a hole.
        float brightness = mix(0.055, 1.0, lit);
        float bloom = pow(saturate(1.0 - dist), 3.0) * 0.28 * (0.3 + 0.7 * k);
        alpha = saturate(disk * brightness + bloom);
    } else if (in.shape == kShapeSunDisk) {
        // Solar disk: a clear limb, plus a bloom whose *relative* extent
        // shrinks as the sprite grows, so zooming in gives a bigger disk and
        // not an ever-larger ball of glare.
        float detail = saturate(in.param2);
        float disk = 1.0 - smoothstep(0.80, 0.87, dist);
        float bloomStrength = mix(0.45, 0.16, detail);
        float bloomPower = mix(2.6, 4.5, detail);
        float bloom = pow(saturate(1.0 - dist), bloomPower) * bloomStrength;
        // A hint of limb darkening: no invented surface detail, just the
        // radial falloff every star actually has.
        float limbDarkening = mix(1.0, 0.90, detail * smoothstep(0.0, 0.80, dist));
        alpha = saturate(disk * limbDarkening + bloom);
    } else if (in.shape == kShapePlanetDisk) {
        // Planetary disk. `param0` = illuminated fraction, `param1` = angle of
        // the bright limb on screen, `param2` = detail level (fades every
        // feature in with zoom), `param3` = which planet.
        float k = clamp(in.param0, 0.0, 1.0);
        float detail = saturate(in.param2);
        int code = int(in.param3 + 0.5);

        float ca = cos(in.param1);
        float sa = sin(in.param1);
        float2 q = float2(p.x * ca + p.y * sa, -p.x * sa + p.y * ca);

        // Saturn's sprite is widened to make room for the rings, so its disk
        // occupies a smaller fraction of the sprite. Must match
        // `StarAppearance.saturnSpriteScale`.
        float spriteScale = (code == kPlanetSaturn) ? mix(1.0, 2.4, detail) : 1.0;
        float diskEdge = 0.86 / spriteScale;

        float edgeSoftness = mix(0.10, 0.035, detail) / spriteScale;
        float disk = 1.0 - smoothstep(diskEdge - edgeSoftness, diskEdge + edgeSoftness * 0.6, dist);

        // Phase. Mercury and Venus swing through real crescents; the outer
        // planets have k ~ 1 so this is a no-op for them. Contrast fades in
        // with detail so a 4-pixel marker is never a crescent sliver.
        float lit = terminatorLit(q, k, diskEdge, mix(0.20, 0.05, detail) / spriteScale);
        float phaseDepth = detail * 0.95;
        float shading = mix(1.0, mix(0.03, 1.0, lit), phaseDepth);

        // Normalised disk coordinates for surface features.
        float2 uv = q / max(diskEdge, 1e-4);
        // Fake a sphere normal so features compress toward the limb the way
        // they do on a real globe.
        float latitude = clamp(uv.y, -1.0, 1.0);

        float3 surface = float3(1.0);
        if (code == kPlanetJupiter) {
            // Two or three very gentle horizontal belts. Understated on
            // purpose: this is a suggestion of banding, not a texture.
            float bands = sin(latitude * 7.5) * 0.5 + sin(latitude * 3.1 + 0.7) * 0.5;
            surface = mix(float3(1.0), float3(1.0) + bands * float3(0.10, 0.055, 0.0), detail);
        } else if (code == kPlanetMars) {
            // Slightly warmer toward the centre, cooler at the limb.
            float centre = 1.0 - saturate(length(uv));
            surface = mix(float3(1.0), float3(1.0) + centre * float3(0.06, 0.01, -0.04), detail);
        } else if (code == kPlanetVenus) {
            // Featureless bright cloud deck — Venus genuinely has no visible
            // surface detail in white light.
            surface = mix(float3(1.0), float3(1.03, 1.02, 0.99), detail);
        } else if (code == kPlanetUranus || code == kPlanetNeptune) {
            // Ice giants: genuinely featureless in visible light. All they get
            // is a fractionally cooler, bluer centre so the disk reads as a
            // sphere rather than a flat coin.
            float centre = 1.0 - saturate(length(uv));
            surface = mix(float3(1.0), float3(1.0) + centre * float3(-0.03, 0.0, 0.05), detail);
        } else if (code == kPlanetMercury) {
            // Grey, airless, and mostly seen as a crescent — the terminator
            // above does all the work here.
            surface = mix(float3(1.0), float3(1.0, 0.99, 0.97), detail);
        }

        // Subtle centre-to-limb brightening falloff for every planet.
        float limbFade = mix(1.0, 0.82, detail * smoothstep(0.35, 1.0, length(uv)));

        rgb = in.color.rgb * surface * limbFade;
        alpha = saturate(disk * shading);

        // Saturn's rings: an ellipse (a circle in the ring plane, foreshortened
        // on screen) drawn around the disk once the sprite is big enough.
        // NOTE: the tilt is a fixed tasteful approximation — the true ring
        // opening angle, which varies from edge-on to ~27 deg over Saturn's
        // 29-year orbit, is NOT computed. See DATA_SOURCES.md.
        if (code == kPlanetSaturn) {
            const float ringTiltY = 0.42;      // foreshortening of the ring plane
            const float ringInner = 1.15;      // in units of the planet's radius
            const float ringOuter = 2.28;      // outer edge of the A ring
            float2 ringP = float2(p.x, p.y / ringTiltY);
            float ringR = length(ringP) / max(diskEdge, 1e-4);
            float ring = smoothstep(ringInner - 0.10, ringInner + 0.05, ringR)
                       * (1.0 - smoothstep(ringOuter - 0.10, ringOuter + 0.06, ringR));
            // Cassini-like gap: one soft dark annulus, nothing more.
            ring *= 1.0 - 0.45 * exp(-0.5 * pow((ringR - 1.95) / 0.06, 2.0));
            ring *= detail * 0.85;
            // Disk draws over the ring; the ring arc that crosses in front of
            // the globe is not modelled.
            alpha = saturate(alpha + ring * (1.0 - alpha));
        }

        // Bloom, tightly bounded, so a planet still reads as a bright point at
        // wide field but does not glare once it is a resolved disk.
        float bloom = pow(saturate(1.0 - dist), 3.0) * mix(0.30, 0.06, detail);
        alpha = saturate(alpha + bloom);
    } else if (in.shape == kShapeDeepSky) {
        // Extended deep-sky object. `param0` = axis ratio (minor/major),
        // `param1` = screen-space angle of the major axis, `param2` = detail
        // level, `param3` = type code.
        //
        // Everything here is procedural and deliberately understated: these
        // are faint, colourless-to-the-eye objects, and the reference look is
        // "a soft patch that resolves into structure as you zoom", not a
        // painted photograph.
        float ratio = clamp(in.param0, 0.05, 1.0);
        float detail = saturate(in.param2);
        int code = int(in.param3 + 0.5);

        float ca = cos(in.param1);
        float sa = sin(in.param1);
        // Rotate so the major axis lies along +x, then squash y by the axis
        // ratio: `r` is 1 on the ellipse and 0 at the centre.
        float2 q = float2(p.x * ca + p.y * sa, -p.x * sa + p.y * ca);
        const float edge = 0.94;
        float r = length(float2(q.x / edge, q.y / (edge * ratio)));

        // Cheap value noise, only ever used to break up an otherwise
        // perfectly smooth blob, and only once the sprite is large enough for
        // it to be legible rather than dithering.
        float2 np = q * 7.0;
        float grain = fract(sin(dot(floor(np), float2(12.9898, 78.233))) * 43758.5453);
        float grain2 = fract(sin(dot(floor(np * 2.3 + 4.1), float2(39.3468, 11.135))) * 24634.6345);

        if (code == kDeepSkyGalaxy) {
            // Soft elongated haze: a broad halo with a distinctly brighter
            // core, both Gaussian so there is no visible sprite edge.
            alpha = 0.45 * exp(-2.3 * r * r) + 0.55 * exp(-8.0 * r * r);
            alpha *= 1.0 + detail * 0.10 * (grain - 0.5);
        } else if (code == kDeepSkyGlobular) {
            // Round (the caller passes ratio 1), sharply concentrated centre,
            // with a soft granular outskirt standing in for resolved members.
            alpha = 0.35 * exp(-2.6 * r * r) + 0.65 * exp(-14.0 * r * r);
            float granular = detail * 0.35 * smoothstep(0.15, 0.75, r) * (grain * grain2);
            alpha += granular * exp(-2.0 * r * r);
        } else if (code == kDeepSkyOpen) {
            // Very understated: the member stars are already drawn from the
            // star catalogue, so this is only a hint that a grouping exists —
            // a faint circular haze with the barest suggestion of a boundary.
            alpha = 0.55 * exp(-2.2 * r * r);
            alpha += 0.25 * exp(-pow((r - 0.72) / 0.26, 2.0)) * detail;
        } else if (code == kDeepSkyPlanetary) {
            // Small, so it mostly reads as a slightly fuzzy dot; the ring
            // only appears once there are pixels to draw it with.
            alpha = 0.75 * exp(-5.0 * r * r);
            alpha += 0.45 * exp(-pow((r - 0.55) / 0.20, 2.0)) * detail;
        } else if (code == kDeepSkyRemnant) {
            // Faint, patchy shell.
            alpha = 0.40 * exp(-2.0 * r * r);
            alpha += 0.35 * exp(-pow((r - 0.70) / 0.28, 2.0)) * (0.6 + 0.4 * grain) * detail;
        } else {
            // Emission/reflection nebula: a broad diffuse glow, lumpy once
            // there is room for lumps.
            alpha = 0.80 * exp(-2.0 * r * r);
            alpha *= 1.0 + detail * 0.28 * (grain * 0.6 + grain2 * 0.4 - 0.5);
        }

        // Nothing outside the ellipse's immediate neighbourhood.
        alpha *= 1.0 - smoothstep(0.90, 1.45, r);
        alpha = saturate(alpha);
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
    return float4(rgb, alpha);
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
