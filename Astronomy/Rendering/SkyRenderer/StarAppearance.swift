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
    ///
    /// The narrow end is 9.0 — the completeness limit of the bundled HYG
    /// catalogue — so pinching all the way in genuinely reaches the bottom of
    /// the data rather than stopping short of it. (It used to be 7.0, which
    /// was a promise the old magnitude-6 catalogue could not keep.) The wide
    /// end stays deliberately shallow: with 83,000 stars available, drawing
    /// them all across a 150-degree field would bury the constellations in
    /// noise, which is the opposite of legible.
    ///
    /// Roughly: 5.4 at 150 deg, 5.9 at 90 deg, 6.2 at 60 deg, 6.9 at 30 deg,
    /// 7.9 at 10 deg, 9.0 at 3 deg.
    static func limitingMagnitude(fieldOfViewDegrees fov: Double) -> Double {
        let wideFOV = 150.0, narrowFOV = 3.0
        let wideLimit = 5.4, narrowLimit = 9.0
        let clamped = min(wideFOV, max(narrowFOV, fov))
        let t = (log(clamped) - log(narrowFOV)) / (log(wideFOV) - log(narrowFOV))
        return narrowLimit + (wideLimit - narrowLimit) * t
    }

    /// The magnitude cutoff actually in force: the more restrictive of the
    /// aesthetic field-of-view limit and the sky-brightness *display* limit.
    ///
    /// The display limit is floored (see `SkyBrightness.displayLimitingMagnitude`)
    /// so the star field is still there in daylight — a planetarium has to
    /// show the sky through the daylight to be useful. At night the physical
    /// limit rises above that floor on its own, so dark skies still gain the
    /// faintest stars naturally and the FOV limit takes over again.
    static func effectiveLimitingMagnitude(
        fieldOfViewDegrees fov: Double,
        sunAltitudeDegrees sunAltitude: Double
    ) -> Double {
        min(
            limitingMagnitude(fieldOfViewDegrees: fov),
            SkyBrightness.displayLimitingMagnitude(sunAltitudeDegrees: sunAltitude)
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
        // A bright sky lowers contrast rather than removing stars, so the
        // field stays legible at noon while still reading as daylight.
        let contrast = SkyBrightness.starContrast(sunAltitudeDegrees: sunAltitude)
        let fadeWidth = 1.1
        if magnitude <= limit - fadeWidth { return contrast }
        if magnitude >= limit { return 0.0 }
        let t = (limit - magnitude) / fadeWidth
        return t * t * (3 - 2 * t) * contrast
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
        // Lifted across the whole range so stars read as the brightest thing in
        // the frame. They now have real competition: 16,000 satellite markers
        // and a photographic Milky Way both sit in the same pixels, and at the
        // old curve a third-magnitude star was smaller than a satellite cross.
        // The exponent is unchanged, so the *hierarchy* between magnitudes is
        // exactly as before — the whole curve is simply brighter.
        let size = 0.55 + 1.95 * pow(relative, 0.62)
        return Float(max(1.15, min(15.5, size)))
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
        // Stronger bloom on the bright stars: the halo is most of what makes
        // Sirius or Vega read as a *star* rather than a dot, and it is the
        // cheapest way to separate them from a satellite marker of similar
        // core size.
        return min(0.58, 0.16 + excess * 0.105)
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
        // Metal caps point sizes at 511 on current Apple GPUs; 500 leaves
        // headroom while still letting a zoomed-in M31 fill the view.
        case .deepSky: return 500
        // Satellites are markers, not resolved objects: even the ISS is 100
        // metres across at 400 km, which is a few arcseconds. There is nothing
        // to zoom into, so the marker stays a marker.
        case .satellite: return 16
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
        // A larger absolute floor than before (3.5), so a dim planet still
        // reads as a planet at a wide field. Deliberately *not* scaled up from
        // `byMagnitude`: the bright planets already inherit the lifted star
        // curve, and inflating the floor further would let it intrude on the
        // zoomed-in regime where the true angular size must dominate and scale
        // linearly (see `testDiskGrowsLinearlyWithZoomOnceTheTrueSizeDominates`).
        // Capped as well as floored. The floor's only job is wide-field
        // visibility; letting the brightest planets carry a 15-point floor all
        // the way in would blunt the smooth-max blend and stop the true angular
        // size dominating cleanly at high zoom.
        case .planet: return max(6.0, min(11.0, byMagnitude))
        case .star: return byMagnitude
        case .deepSky: return deepSkyMinimumSize
        case .satellite: return satelliteMarkerSize
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

    // MARK: - Deep-sky objects

    /// Minimum drawn diameter, in points, for a deep-sky object whose true
    /// angular extent projects to less than this. Chosen to be a comfortable
    /// click target (the hit-test tolerance is 22 pt) and large enough that a
    /// small distant galaxy still reads as a fuzzy patch rather than a star.
    static let deepSkyMinimumSize = 9.0

    // MARK: - Satellites

    /// Base marker diameter, in points. Small on purpose: there can be
    /// hundreds on screen and they are furniture around the sky, not the
    /// subject of it.
    static let satelliteMarkerSize = 7.0

    /// Marker diameter for a satellite. Grows gently with zoom — enough that a
    /// zoomed-in pass is comfortable to watch and to click, nowhere near enough
    /// to compete with a planet's disk.
    static func satellitePointSize(
        fieldOfViewDegrees fov: Double, isNotable: Bool
    ) -> Float {
        let zoom = fadeInSize(value: 70.0 - fov, over: 60.0)
        let base = satelliteMarkerSize + 3.5 * zoom
        return Float(isNotable ? base * 1.35 : base)
    }

    /// Satellite tint. Cool and desaturated: these are the one artificial thing
    /// in the view and the palette says so quietly, with a faint cyan cast that
    /// no star or deep-sky object in the ramp above ever reaches.
    static let satelliteColor = SIMD4<Float>(0.62, 0.86, 0.92, 1.0)
    /// Notable objects get a slightly warmer, brighter tint so the ISS is
    /// findable among a hundred anonymous Starlinks.
    static let satelliteNotableColor = SIMD4<Float>(0.98, 0.90, 0.72, 1.0)

    /// Brightness multiplier for a satellite's illumination state.
    ///
    /// A satellite is only genuinely visible from the ground when sunlight is
    /// falling on it. An eclipsed one is still *there* — this is a planetarium,
    /// and "where is it right now" is a fair question — so it is drawn, but at
    /// a fraction of the brightness, which is what makes a pass fading out at
    /// shadow entry read correctly.
    static func satelliteIlluminationFactor(
        _ illumination: TopocentricTransform.Illumination
    ) -> Double {
        switch illumination {
        case .sunlit: return 1.0
        case .penumbra: return 0.45
        case .umbra: return 0.18
        }
    }

    /// Local smoothstep helper for the size curves above; mirrors
    /// `SkyGeometryBuilder.fadeIn` so the two read alike.
    private static func fadeInSize(value: Double, over width: Double) -> Double {
        guard width > 0 else { return value > 0 ? 1 : 0 }
        let t = min(1.0, max(0.0, value / width))
        return t * t * (3 - 2 * t)
    }

    /// Screen diameter in points along the *major* axis of a deep-sky object.
    ///
    ///     pointsPerDegree = viewportWidth / fieldOfViewDegrees
    ///     trueSize        = majorAxisArcmin / 60 * pointsPerDegree
    ///     size            = min(ceiling, smoothMax(trueSize, floor))
    ///
    /// Exactly the shape `solarSystemPointSize` uses, and for the same reason:
    /// the truthful term is linear in the zoom factor and dominates once you
    /// are zoomed in, the floor dominates at wide field, and `smoothMax`
    /// blends the crossover without a pop. M31's 177.8 arcmin is ~2.96 deg, so
    /// on a 1600 pt viewport at a 60 deg field it spans ~79 pt — about 5% of
    /// the screen width, which is what makes it read as a real object.
    ///
    /// The sprite is square and the ellipse is inscribed in it, so the major
    /// axis fits at any rotation.
    static func deepSkyPointSize(
        majorAxisArcmin: Double?,
        fieldOfViewDegrees fov: Double,
        viewportWidth: Double
    ) -> Float {
        let pointsPerDegree = max(1.0, viewportWidth / max(fov, 0.001))
        let trueSize = ((majorAxisArcmin ?? 0) / 60.0) * pointsPerDegree
        let floorSize = deepSkyMinimumSize
        let blended = smoothMax(trueSize, floorSize, softness: floorSize * 0.75)
        return Float(min(maximumPointSize(kind: .deepSky), blended))
    }

    /// Axis ratio (minor / major) used to squash the drawn ellipse. Falls back
    /// to 1 (a circle) when either axis is missing, and is floored so a very
    /// thin edge-on galaxy is still a few pixels wide.
    static func deepSkyAxisRatio(majorAxisArcmin: Double?, minorAxisArcmin: Double?) -> Double {
        guard let major = majorAxisArcmin, major > 0,
              let minor = minorAxisArcmin, minor > 0 else { return 1.0 }
        return min(1.0, max(0.12, minor / major))
    }

    /// Magnitude used for *visibility* decisions, biased by surface brightness.
    ///
    /// APPROXIMATION. Naked-eye detectability of an extended object is governed
    /// by surface brightness, not integrated magnitude: a magnitude 8 galaxy
    /// smeared over 20 arcmin is far harder than a magnitude 8 star. The exact
    /// mean surface brightness is `m + 2.5 log10(area)` in mag/arcsec^2, which
    /// is not on the same scale as stellar magnitudes and cannot be fed to the
    /// star limiting-magnitude curves directly. So instead this applies a
    /// *bounded fraction* of that penalty:
    ///
    ///     penalty = clamp(0.5 * 2.5 * log10(area / 50), 0, 1.2)
    ///
    /// Objects smaller than ~50 arcmin^2 (about 8 arcmin across) get no
    /// penalty; the penalty saturates at 1.2 magnitudes so that genuinely
    /// famous large objects (M31 at 3.4, M45 at 1.2) stay visible at a wide
    /// field on a dark night, while a mag 10 galaxy still needs zoom. The cap
    /// is an aesthetic choice, not physics.
    static func deepSkyDetectionMagnitude(
        magnitude: Double,
        majorAxisArcmin: Double?,
        minorAxisArcmin: Double?
    ) -> Double {
        guard let major = majorAxisArcmin, major > 0 else { return magnitude }
        let minor = minorAxisArcmin ?? major
        let area = .pi / 4.0 * major * max(minor, 0.1)
        guard area > 50 else { return magnitude }
        let penalty = min(1.2, 0.5 * 2.5 * log10(area / 50.0))
        return magnitude + penalty
    }

    /// Extra twilight suppression applied to deep-sky objects on top of the
    /// shared star visibility model: 0 while the Sun is up, rising to 1 by the
    /// end of nautical twilight.
    ///
    /// The star path deliberately floors its daylight contrast at 0.72 so the
    /// constellations stay legible through a bright sky — a planetarium
    /// convention, and one the rest of this app keeps. That convention is wrong
    /// for extended objects: a galaxy is a low-surface-brightness smear that
    /// competes with the sky *background*, not a point source competing with
    /// its neighbourhood, so it is genuinely gone long before the stars are.
    /// Faint fuzzy patches painted over a blue noon sky would also simply look
    /// like a rendering bug.
    static func deepSkyTwilightFactor(sunAltitudeDegrees sunAltitude: Double) -> Double {
        SkyGeometryBuilder.fadeIn(value: -2.0 - sunAltitude, over: 10.0)
    }

    /// Per-type tint. Deliberately close to white: real deep-sky objects are
    /// colourless to the eye, and saturated blobs would fight the muted
    /// palette the rest of the sky uses. Only planetaries (cool) and emission
    /// nebulae (warm, standing in for H-II red) carry a perceptible cast.
    static func deepSkyColor(type: DeepSkyType) -> SIMD4<Float> {
        switch type {
        case .galaxy:           return SIMD4(1.00, 0.97, 0.92, 1.0)
        case .globularCluster:  return SIMD4(1.00, 0.98, 0.91, 1.0)
        case .openCluster:      return SIMD4(0.92, 0.95, 1.00, 1.0)
        case .nebula:           return SIMD4(1.00, 0.88, 0.85, 1.0)
        case .planetaryNebula:  return SIMD4(0.80, 0.95, 0.95, 1.0)
        case .supernovaRemnant: return SIMD4(0.96, 0.90, 0.92, 1.0)
        case .darkNebula:       return SIMD4(0.50, 0.50, 0.52, 1.0)
        }
    }

    /// Overall opacity multiplier per type, before the visibility model. Open
    /// clusters are heavily understated because their member stars are already
    /// drawn from the star catalogue — the haze is only a hint that a grouping
    /// exists, never a second copy of the cluster.
    static func deepSkyOpacity(type: DeepSkyType) -> Double {
        switch type {
        case .galaxy:           return 0.62
        case .globularCluster:  return 0.62
        case .openCluster:      return 0.20
        case .nebula:           return 0.52
        case .planetaryNebula:  return 0.60
        case .supernovaRemnant: return 0.42
        case .darkNebula:       return 0.0
        }
    }

    /// Numeric identity passed to the shader so it can pick a deep-sky
    /// object's procedural treatment. Keep in sync with `Shaders.metal`.
    static func deepSkyShaderCode(type: DeepSkyType) -> Float {
        switch type {
        case .galaxy:           return 0
        case .globularCluster:  return 1
        case .openCluster:      return 2
        case .nebula:           return 3
        case .planetaryNebula:  return 4
        case .supernovaRemnant: return 5
        case .darkNebula:       return 6
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
