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

    /// Opacity multiplier for a star, fading it out over the last magnitude
    /// before the cutoff so stars dissolve instead of popping.
    static func visibility(magnitude: Double, fieldOfViewDegrees fov: Double) -> Double {
        let limit = limitingMagnitude(fieldOfViewDegrees: fov)
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

    /// Angular diameter, in degrees, used to size a solar-system disk.
    /// The Sun and Moon get their true ~0.5 deg; planets are point sources to
    /// the naked eye, so they get a small floor instead so they never vanish.
    static func angularDiameterDegrees(kind: CelestialObjectKind) -> Double {
        switch kind {
        case .sun, .moon: return 0.53
        case .planet: return 0.02
        case .star: return 0.0
        }
    }

    /// Screen diameter in points for a solar-system body: its true angular
    /// size where that dominates, with a magnitude-driven floor so a planet
    /// still reads as a bright point at wide field, and a ceiling so nothing
    /// becomes a giant blob when zoomed in.
    static func solarSystemPointSize(
        kind: CelestialObjectKind,
        magnitude: Double,
        fieldOfViewDegrees fov: Double,
        viewportWidth: Double
    ) -> Float {
        let pointsPerDegree = max(1.0, viewportWidth / max(fov, 0.001))
        let angular = angularDiameterDegrees(kind: kind) * pointsPerDegree
        let floorSize = Double(pointSize(forMagnitude: magnitude))
        let raw = max(angular, floorSize)
        switch kind {
        case .sun: return Float(min(120.0, max(14.0, raw)))
        case .moon: return Float(min(140.0, max(12.0, raw)))
        case .planet: return Float(min(46.0, max(3.0, raw)))
        case .star: return pointSize(forMagnitude: magnitude)
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
