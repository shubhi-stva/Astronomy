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
    /// end was 5.4, chosen to keep constellations legible. That was too
    /// cautious: it left a wide field looking sparse next to a real dark sky,
    /// where the faint field is dense and is most of what makes the view feel
    /// deep. 6.5 is about three times as many stars at 150 degrees, and the
    /// size curve is steep enough (see `pointSize`) that the constellation
    /// stars still dominate the faint dust around them.
    ///
    /// Roughly: 6.5 at 150 deg, 6.8 at 90 deg, 7.1 at 60 deg, 7.5 at 30 deg,
    /// 8.2 at 10 deg, 9.0 at 3 deg.
    static func limitingMagnitude(fieldOfViewDegrees fov: Double) -> Double {
        let wideFOV = 150.0, narrowFOV = 3.0
        let wideLimit = 6.5, narrowLimit = 9.0
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

    /// Per-planet tints, chosen to match how each body actually looks rather
    /// than to be maximally distinguishable.
    ///
    /// Two things are going on at once and they pull in opposite directions.
    /// At a wide field a planet is a handful of pixels and the tint is *all*
    /// the information there is, so it has to be legible. Zoomed in the tint
    /// multiplies the surface texture (see `Shaders.metal`), so an
    /// over-saturated tint would stain a real photographic map. Every value
    /// below is therefore the honest colour of the body, not a boosted one.
    ///
    /// Mars specifically: Mars is **not** red. Its integrated colour, from the
    /// Viking and MRO colour mosaics and from every naked-eye description, is
    /// a muted ochre — closer to butterscotch or dried terracotta than to
    /// anything fire-engine. `marsSaturationRange` pins that so a future edit
    /// cannot quietly crank it; `AstronomyTests` asserts it.
    ///
    /// - mercury: grey, faintly warm — an airless basalt world.
    /// - venus: pale cream-white — a featureless sulphuric cloud deck.
    /// - mars: muted ochre-red (see above).
    /// - jupiter: warm tan, the mean of its belts and zones.
    /// - saturn: pale gold, a shade less contrasty than Jupiter.
    /// - uranus: pale cyan, from methane absorption in the red.
    /// - neptune: deeper blue — the same chemistry, a deeper atmosphere.
    static func planetColor(id: String) -> SIMD4<Float> {
        switch id {
        case "mercury": return SIMD4(0.78, 0.77, 0.74, 1.0)
        case "venus":   return SIMD4(1.00, 0.98, 0.91, 1.0)
        case "mars":    return SIMD4(0.86, 0.59, 0.44, 1.0)
        case "jupiter": return SIMD4(0.94, 0.86, 0.72, 1.0)
        case "saturn":  return SIMD4(0.94, 0.87, 0.68, 1.0)
        case "uranus":  return SIMD4(0.68, 0.87, 0.90, 1.0)
        case "neptune": return SIMD4(0.48, 0.60, 0.86, 1.0)
        default:        return SIMD4(0.88, 0.92, 0.96, 1.0)
        }
    }

    /// The band Mars's tint saturation is allowed to occupy, as
    /// `(max - min) / max` over the RGB channels.
    ///
    /// Below the floor Mars stops reading as the distinctly warm object it is
    /// and becomes another beige dot. Above the ceiling it becomes the
    /// cartoon red planet the user explicitly rejected. Pinned as a constant
    /// rather than as a bare number in a test so the intent lives next to the
    /// colour it constrains.
    static let marsSaturationRange: ClosedRange<Float> = 0.35...0.58

    // MARK: - Aura

    /// The soft halo drawn *behind* a solar-system body: size in points, alpha,
    /// and the colour to draw it in.
    struct Aura: Equatable {
        var size: Float
        var alpha: Float
        var color: SIMD4<Float>
    }

    /// Apparent magnitude at or below which a solar-system body earns an aura.
    ///
    /// 3.0 is roughly where a planet stops being an obviously bright thing in
    /// the sky. Saturn (~0.5) and everything brighter glow; Uranus (~5.7) and
    /// Neptune (~7.8) get essentially nothing, which is correct — they are
    /// telescopic objects and a halo would be a lie about how they read.
    static let auraMagnitudeThreshold = 3.0

    /// Ceiling on aura alpha for a planet. The Sun is allowed past this; a
    /// planet never is.
    static let planetAuraMaximumAlpha: Float = 0.30

    /// How much of a body's aura is dissolved once its disk is fully resolved.
    ///
    /// This is the single most important number for taste. A halo is how a
    /// body reads as *bright* when it is a few pixels across; once it is a
    /// resolved disk with a terminator and a surface map on it, the same halo
    /// is glare sitting on top of the thing you zoomed in to look at. So every
    /// aura fades as `detailLevel` rises. The Moon's is the strongest damping
    /// of the three because its terminator is the feature most easily washed
    /// out, and the Sun's is the weakest because a Sun without glare is wrong
    /// at any size.
    private static func auraDetailDamping(kind: CelestialObjectKind) -> Float {
        switch kind {
        case .sun: return 0.35
        case .moon: return 0.62
        default: return 0.60
        }
    }

    /// The aura for a solar-system body, or nil if it has not earned one.
    ///
    /// Deliberately derived from *measured* quantities — the body's apparent
    /// magnitude and the diameter it is actually being drawn at — rather than
    /// hard-coded per body. That means Mars near opposition (magnitude -2.9)
    /// genuinely blooms more than Mars near conjunction (+1.6), Venus always
    /// outshines everything, and adding a body needs no new case here.
    ///
    /// The size model mirrors the Sun's: a multiple of the disk, smooth-minned
    /// against a bounded offset from it, so the halo dominates at wide field
    /// and then *stops growing* instead of swallowing the frame as you zoom.
    ///
    /// The colour is the body's tint pulled part-way to white. A halo carries
    /// far more pixels than the disk does, so drawing it in the body's full
    /// saturation is what turns a subtle ochre Mars into a red smear. Pulling
    /// it toward white keeps the hue and drops the intensity.
    static func aura(
        kind: CelestialObjectKind,
        magnitude: Double,
        tint: SIMD4<Float>,
        pointSize size: Float,
        illuminatedFraction: Double = 1.0
    ) -> Aura? {
        let detail = detailLevel(pointSize: size)
        let damping = 1.0 - auraDetailDamping(kind: kind) * detail

        let baseAlpha: Float
        let haloSize: Float
        let color: SIMD4<Float>

        switch kind {
        case .sun:
            baseAlpha = 0.40
            haloSize = Float(smoothMin(
                Double(size) * 3.4, Double(size) * 1.25 + 110.0, softness: 40.0
            ))
            color = whitened(sunColor, by: 0.15)

        case .moon:
            // Scaled by the illuminated fraction: a new Moon has no halo
            // because there is nothing lit to scatter, and a full Moon has a
            // pronounced one. Kept well under the Sun's — the Moon glows, it
            // does not glare.
            let k = Float(max(0, min(1, illuminatedFraction)))
            baseAlpha = 0.05 + 0.20 * k
            haloSize = Float(smoothMin(
                Double(size) * 2.6, Double(size) * 1.20 + 80.0, softness: 30.0
            ))
            color = whitened(moonColor, by: 0.25)

        case .planet, .dwarfPlanet:
            let excess = Float(max(0.0, auraMagnitudeThreshold - magnitude))
            guard excess > 0 else { return nil }
            // Linear in magnitude, i.e. logarithmic in flux, which is the
            // right shape: it separates Venus from Jupiter without letting
            // Venus be five times the halo of Mars.
            //
            // Note the absence of a constant term. The halo has to start at
            // *zero* strength exactly at the threshold, or a planet brightening
            // toward opposition pops a faint halo into existence the moment it
            // crosses magnitude 3. The slope is then set so Venus lands on the
            // ceiling and everything dimmer stays comfortably under it.
            baseAlpha = min(planetAuraMaximumAlpha, 0.040 * excess)
            // Brighter planets also get a slightly *wider* halo, not just a
            // denser one, because that is how glare actually behaves.
            let widthBoost = Double(min(1.0, excess / 6.0))
            haloSize = Float(smoothMin(
                Double(size) * (2.4 + 1.1 * widthBoost),
                Double(size) * 1.20 + 55.0 + 25.0 * widthBoost,
                softness: 22.0
            ))
            color = whitened(tint, by: 0.35)

        case .star, .deepSky, .satellite, .constellation:
            return nil
        }

        let alpha = baseAlpha * damping
        guard alpha > 0.0005 else { return nil }
        return Aura(size: min(200, haloSize), alpha: alpha, color: color)
    }

    /// Pulls a colour `amount` of the way toward white, preserving hue.
    private static func whitened(_ c: SIMD4<Float>, by amount: Float) -> SIMD4<Float> {
        let t = max(0, min(1, amount))
        return SIMD4(
            c.x + (1 - c.x) * t,
            c.y + (1 - c.y) * t,
            c.z + (1 - c.z) * t,
            c.w
        )
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
        // IAU/New Horizons mean radius. Kept for completeness; at 30+ AU the
        // marker floor dominates at every field of view.
        case "pluto":   return 1_188.3
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
        // Pluto's true disk is about 0.1 arcsec across — it never resolves at
        // any field of view this app allows, so the ceiling only has to be
        // clear of the marker floor.
        case .dwarfPlanet: return 40
        case .star: return 13
        // Metal caps point sizes at 511 on current Apple GPUs; 500 leaves
        // headroom while still letting a zoomed-in M31 fill the view.
        case .deepSky: return 500
        // Satellites are markers, not resolved objects: even the ISS is 100
        // metres across at 400 km, which is a few arcseconds. There is nothing
        // to zoom into, so the marker stays a marker.
        case .satellite: return 16
        // Never drawn. Present for exhaustiveness only.
        case .constellation: return 0
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
        // A deliberately small marker: a dwarf planet is a point of light far
        // below the naked-eye limit, and it should read as one when revealed
        // by selection rather than as another planet.
        case .dwarfPlanet: return 5.0
        case .star: return byMagnitude
        case .deepSky: return deepSkyMinimumSize
        case .satellite: return satelliteMarkerSize
        case .constellation: return 0
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
