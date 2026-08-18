//
//  StarAppearance.swift
//  Astronomy
//
//  Maps physical quantities (B-V colour index, apparent magnitude) and the
//  current field of view to the RGBA colour, size and opacity used for
//  rendering.
//
//  Colour: approximate but physically motivated. B-V < 0 is hot/blue-white,
//  B-V ~ 0.65 is Sun-like yellow-white, B-V > 1.5 is cool/red-orange. Real
//  naked-eye stars are far less saturated than a naive blackbody ramp
//  suggests, because at low light levels colour vision is barely engaged, so
//  every stop below is deliberately pulled toward white — a subtle tint, not a
//  rainbow.
//
//  Size/opacity: the visual hierarchy is driven mostly by *area* and glow, not
//  by opacity alone, which is what makes a real sky read as depth rather than
//  a scatter plot.
//

import Foundation
import simd

enum StarAppearance {

    // MARK: - Colour

    /// Piecewise-linear B-V -> RGB ramp. Anchors chosen so the mid-range
    /// (most naked-eye stars) sits within a few percent of neutral white and
    /// only the extremes carry a visible tint.
    private static let colorStops: [(bv: Double, rgb: SIMD3<Float>)] = [
        (-0.40, SIMD3(0.68, 0.78, 1.00)),   // O/B — cool blue-white
        (-0.10, SIMD3(0.80, 0.86, 1.00)),   // B/A — blue-white
        (0.10, SIMD3(0.91, 0.94, 1.00)),    // A — white with a blue cast
        (0.35, SIMD3(0.99, 0.99, 0.97)),    // F — essentially white
        (0.65, SIMD3(1.00, 0.96, 0.87)),    // G — Sun-like, warm white
        (1.00, SIMD3(1.00, 0.89, 0.74)),    // K — pale amber
        (1.50, SIMD3(1.00, 0.80, 0.62)),    // K/M — orange
        (2.00, SIMD3(1.00, 0.71, 0.55)),    // M — red-orange (never pure red)
    ]

    static func color(colorIndex: Double?) -> SIMD4<Float> {
        guard let bv = colorIndex else {
            return SIMD4(0.93, 0.95, 0.99, 1.0)
        }
        let clamped = max(colorStops.first!.bv, min(colorStops.last!.bv, bv))
        for i in 0..<(colorStops.count - 1) {
            let (t0, c0) = colorStops[i]
            let (t1, c1) = colorStops[i + 1]
            if clamped >= t0 && clamped <= t1 {
                let t = Float((clamped - t0) / (t1 - t0))
                return SIMD4(mix(c0, c1, t: t), 1.0)
            }
        }
        return SIMD4(colorStops.last!.rgb, 1.0)
    }

    private static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }

    // MARK: - Visibility

    /// Magnitude of the faintest star drawn at a given field of view.
    ///
    /// Wide field: only the stars that actually structure the sky, so the view
    /// reads as constellations rather than noise. Zoomed in: the faint field
    /// fills back in. Interpolated on log(FOV) so the fill-in feels linear as
    /// you pinch.
    static func limitingMagnitude(fieldOfViewDegrees fov: Double) -> Double {
        let wideFOV = 150.0, narrowFOV = 3.0
        let wideLimit = 4.6, narrowLimit = 7.0
        let clamped = min(wideFOV, max(narrowFOV, fov))
        let t = (log(clamped) - log(narrowFOV)) / (log(wideFOV) - log(narrowFOV))
        return narrowLimit + (wideLimit - narrowLimit) * t
    }

    /// The magnitude cutoff actually in force: the more restrictive of the
    /// aesthetic field-of-view limit and the physical sky-brightness limit
    /// (`SkyBrightness`). In daylight the sky limit dominates and drops to
    /// about -3.9, so the star field simply is not there; by astronomical
    /// night the sky limit has risen past 6 and the FOV limit takes over
    /// again, exactly as before this existed.
    static func effectiveLimitingMagnitude(
        fieldOfViewDegrees fov: Double,
        sunAltitudeDegrees sunAltitude: Double
    ) -> Double {
        min(
            limitingMagnitude(fieldOfViewDegrees: fov),
            SkyBrightness.limitingMagnitude(sunAltitudeDegrees: sunAltitude)
        )
    }

    /// Opacity multiplier for an object, fading it out over the last magnitude
    /// before the cutoff so objects dissolve instead of popping.
    ///
    /// Note the fade is *magnitude-dependent*, not a global daylight dimmer:
    /// as the limit sweeps down through sunset, mag 5 stars vanish long before
    /// mag 1 ones, and Venus outlasts everything. That ordering is the whole
    /// point — a uniform opacity multiplier would keep the faint field visible
    /// (just dimmer) in broad daylight, which is exactly the wrong look.
    static func visibility(
        magnitude: Double,
        fieldOfViewDegrees fov: Double,
        sunAltitudeDegrees sunAltitude: Double = -90
    ) -> Double {
        let limit = effectiveLimitingMagnitude(
            fieldOfViewDegrees: fov,
            sunAltitudeDegrees: sunAltitude
        )
        let fadeWidth = 1.1
        if magnitude <= limit - fadeWidth { return 1.0 }
        if magnitude >= limit { return 0.0 }
        let t = (limit - magnitude) / fadeWidth
        return t * t * (3 - 2 * t)
    }

    // MARK: - Size

    /// Magnitude below which a star earns a glow halo.
    static let glowMagnitudeThreshold = 1.6

    /// Point sprite diameter in points for a star of a given apparent
    /// magnitude.
    ///
    /// Real perceived star size on a screen grows roughly with the square root
    /// of flux, and flux is 10^(-0.4 m). A pure power law makes Sirius a blob,
    /// so the exponent is softened and the result clamped — but it is still a
    /// much steeper ramp than a linear-in-magnitude curve, which is what gives
    /// the field its hierarchy.
    static func pointSize(forMagnitude magnitude: Double) -> Float {
        let clampedMag = max(-1.5, min(8.0, magnitude))
        // Normalised brightness relative to magnitude 6.5 (naked-eye limit).
        let relative = pow(10.0, -0.25 * (clampedMag - 6.5))
        let size = 0.35 + 1.35 * pow(relative, 0.62)
        return Float(max(0.8, min(13.0, size)))
    }

    /// Diameter of the soft halo drawn behind a bright star.
    static func glowSize(forMagnitude magnitude: Double) -> Float {
        let core = pointSize(forMagnitude: magnitude)
        let excess = Float(max(0.0, glowMagnitudeThreshold - magnitude))
        return min(58.0, core * (2.6 + excess * 1.5))
    }

    /// Alpha of that halo — brighter stars bloom harder, but never above a
    /// gentle ceiling.
    static func glowAlpha(forMagnitude magnitude: Double) -> Float {
        let excess = Float(max(0.0, glowMagnitudeThreshold - magnitude))
        return min(0.42, 0.10 + excess * 0.075)
    }

    // MARK: - Solar system

    static let sunColor = SIMD4<Float>(1.0, 0.92, 0.70, 1.0)
    static let moonColor = SIMD4<Float>(0.93, 0.93, 0.90, 1.0)

    /// Subtly distinct per-planet tints — enough to separate them from the
    /// star field at a glance without looking like coloured markers.
    static func planetColor(id: String) -> SIMD4<Float> {
        switch id {
        case "mercury": return SIMD4(0.86, 0.84, 0.79, 1.0)
        case "venus":   return SIMD4(1.00, 0.97, 0.86, 1.0)
        case "mars":    return SIMD4(1.00, 0.72, 0.58, 1.0)
        case "jupiter": return SIMD4(1.00, 0.92, 0.78, 1.0)
        case "saturn":  return SIMD4(0.98, 0.91, 0.72, 1.0)
        case "uranus":  return SIMD4(0.74, 0.92, 0.95, 1.0)
        case "neptune": return SIMD4(0.68, 0.80, 0.98, 1.0)
        default:        return SIMD4(0.88, 0.92, 0.96, 1.0)
        }
    }

    /// Mean equatorial radii in kilometres.
    ///
    /// Source: NASA/GSFC Planetary Fact Sheets (equatorial radius, itself
    /// derived from the IAU Working Group on Cartographic Coordinates and
    /// Rotational Elements report). See DATA_SOURCES.md.
    static func equatorialRadiusKilometres(objectID id: String) -> Double? {
        switch id {
        case "sun":     return 696_000.0
        case "moon":    return 1_737.4
        case "mercury": return 2_439.7
        case "venus":   return 6_051.8
        case "mars":    return 3_389.5
        case "jupiter": return 71_492.0
        case "saturn":  return 60_268.0
        case "uranus":  return 25_559.0
        case "neptune": return 24_764.0
        default:        return nil
        }
    }

    /// True apparent angular diameter of a body, in degrees:
    /// `2 * atan(radius / distance)`, using the real equatorial radius above
    /// and the *current* distance from the ephemeris. This is what makes Mars
    /// swell near opposition and the Moon change size between perigee and
    /// apogee — the old code returned a flat 0.02 deg for every planet, so
    /// nothing ever changed and no planet ever resolved into a disk.
    ///
    /// Returns 0 for anything without a radius (stars — unresolvable).
    static func angularDiameterDegrees(objectID id: String, distanceKilometres: Double?) -> Double {
        guard let radius = equatorialRadiusKilometres(objectID: id),
              let distance = distanceKilometres, distance > radius else { return 0 }
        return 2 * atan(radius / distance) * 180.0 / .pi
    }

    /// Smooth analogue of `max(a, b)`.
    ///
    /// `0.5 * (a + b + sqrt((a-b)^2 + k^2))` is >= max(a, b), exceeds it by at
    /// most k/2 (where the two curves cross), and is differentiable
    /// everywhere. Used instead of a hard `max` so the moment the true angular
    /// size overtakes the minimum visualisation size — which happens *while
    /// the user is pinching* — has no kink or pop in it.
    static func smoothMax(_ a: Double, _ b: Double, softness k: Double) -> Double {
        0.5 * (a + b + ((a - b) * (a - b) + k * k).squareRoot())
    }

    /// Smooth analogue of `min(a, b)`. Mirror of `smoothMax`.
    static func smoothMin(_ a: Double, _ b: Double, softness k: Double) -> Double {
        0.5 * (a + b - ((a - b) * (a - b) + k * k).squareRoot())
    }

    /// Ceiling on rendered disk diameter, in points, per kind. Generous: the
    /// point of zooming in is to see a disk, and a point sprite is cheap. The
    /// ceiling exists only so an extreme zoom cannot exceed the GPU's maximum
    /// point size.
    static func maximumPointSize(kind: CelestialObjectKind) -> Double {
        switch kind {
        case .sun: return 300
        case .moon: return 340
        case .planet: return 260
        case .star: return 13
        }
    }

    /// Minimum visualisation size, in points: the diameter a body is drawn at
    /// when its true angular size is too small to see or click. Driven by
    /// magnitude (a bright planet earns a bigger marker than a faint one),
    /// with a hard floor per kind.
    static func minimumVisualizationSize(kind: CelestialObjectKind, magnitude: Double) -> Double {
        let byMagnitude = Double(pointSize(forMagnitude: magnitude))
        switch kind {
        case .sun: return max(14.0, byMagnitude)
        case .moon: return max(12.0, byMagnitude)
        case .planet: return max(3.5, byMagnitude)
        case .star: return byMagnitude
        }
    }

    /// Screen diameter in points for a solar-system body.
    ///
    ///     pointsPerDegree = viewportWidth / fieldOfViewDegrees
    ///     trueSize        = angularDiameterDegrees * pointsPerDegree
    ///     size            = min(ceiling, smoothMax(trueSize, floor))
    ///
    /// `trueSize` is the truthful term and it is linear in the zoom factor, so
    /// it dominates completely once you are zoomed in: halve the field of
    /// view, double the disk. `floor` is the documented minimum visualisation
    /// size, which dominates at wide field where the true disk would be a
    /// fraction of a pixel. `smoothMax` blends the two with no kink.
    static func solarSystemPointSize(
        objectID: String,
        kind: CelestialObjectKind,
        magnitude: Double,
        distanceKilometres: Double?,
        fieldOfViewDegrees fov: Double,
        viewportWidth: Double
    ) -> Float {
        guard kind != .star else { return pointSize(forMagnitude: magnitude) }

        let pointsPerDegree = max(1.0, viewportWidth / max(fov, 0.001))
        let trueSize = angularDiameterDegrees(objectID: objectID, distanceKilometres: distanceKilometres)
            * pointsPerDegree
        let floorSize = minimumVisualizationSize(kind: kind, magnitude: magnitude)

        // Softness proportional to the floor, so the blend region scales with
        // the marker and is never a fixed number of pixels.
        let blended = smoothMax(trueSize, floorSize, softness: floorSize * 0.75)
        return Float(min(maximumPointSize(kind: kind), blended))
    }

    /// How far the rendered disk has grown past the point where surface
    /// detail is worth drawing: 0 below `detailStart` points across, 1 above
    /// `detailFull`, smoothstepped between. Multiplies every procedural
    /// feature (bands, rings, terminator contrast) so nothing ever appears
    /// abruptly as you pinch.
    static func detailLevel(pointSize size: Float) -> Float {
        let start: Float = 16, full: Float = 52
        let t = max(0, min(1, (size - start) / (full - start)))
        return t * t * (3 - 2 * t)
    }

    /// Saturn's sprite is widened so the rings have somewhere to live: the
    /// planet's disk occupies only `1 / ringSpriteScale` of the sprite. The
    /// scale itself fades in with detail so the sprite is a plain disk when
    /// small. The shader recomputes this identically — keep the two in sync.
    static let saturnRingSpriteScale: Float = 2.4

    static func saturnSpriteScale(detail: Float) -> Float {
        1.0 + (saturnRingSpriteScale - 1.0) * detail
    }

    /// Numeric identity passed to the shader so it can pick a planet's
    /// procedural treatment. Keep in sync with `Shaders.metal`.
    static func planetShaderCode(id: String) -> Float {
        switch id {
        case "mercury": return 0
        case "venus":   return 1
        case "mars":    return 2
        case "jupiter": return 3
        case "saturn":  return 4
        case "uranus":  return 5
        case "neptune": return 6
        default:        return 7
        }
    }

    // MARK: - Constellation lines

    /// Base colour of a constellation line: a muted blue-grey that reads as
    /// structure without competing with the stars.
    static let constellationLineRGB = SIMD3<Float>(0.46, 0.58, 0.76)

    /// Line alpha as a function of field of view. Nearly invisible when the
    /// whole sky is on screen, gently present once you've zoomed into a single
    /// constellation, then eased back off at extreme magnification where the
    /// lines run off-screen anyway.
    static func constellationLineAlpha(fieldOfViewDegrees fov: Double) -> Float {
        let wide = 120.0, sweet = 45.0, tight = 8.0
        let alpha: Double
        if fov >= wide {
            alpha = 0.07
        } else if fov >= sweet {
            let t = (wide - fov) / (wide - sweet)
            alpha = 0.07 + (0.26 - 0.07) * t
        } else if fov >= tight {
            alpha = 0.26
        } else {
            alpha = 0.26 * (fov / tight)
        }
        return Float(alpha)
    }

    static func constellationLineColor(fieldOfViewDegrees fov: Double) -> SIMD4<Float> {
        SIMD4(constellationLineRGB, constellationLineAlpha(fieldOfViewDegrees: fov))
    }

    static let selectionRingColor = SIMD4<Float>(0.55, 0.78, 1.0, 0.85)
}
