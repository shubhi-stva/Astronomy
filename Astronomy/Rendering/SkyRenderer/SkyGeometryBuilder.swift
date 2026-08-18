//
//  SkyGeometryBuilder.swift
//  Astronomy
//
//  The CPU half of the "CPU projects, GPU rasterizes" split: consumes one
//  `SkyFrameData` snapshot and produces the point/line vertex buffers, the
//  hit-test table, and the label candidates for a single frame.
//
//  Kept separate from `SkyRenderer` so the projection/visual-hierarchy logic
//  is readable (and reasonable about) without Metal boilerplate in the way.
//
//  Cost per frame over the ~83k-star catalogue is kept down by two cheap
//  rejections that both run before any trigonometry:
//
//    * spatial — `StarIndex` dices the sky into 5-degree cells with
//      precomputed bounding cones, and only cells whose cone can intersect
//      the viewport cone are opened at all;
//    * magnitude — cells store their stars magnitude-ascending, so the scan
//      of a surviving cell stops at the first star fainter than the limit.
//
//  The two cover each other's weak case. At a wide field the limit is low
//  (~5.4) so the magnitude cut does the work; at a narrow field the limit
//  reaches 9.0 but the spatial cut leaves a handful of cells. The awkward
//  middle — moderate field, moderate limit — is exactly where the grid earns
//  its keep.
//

import CoreGraphics
import Foundation
import simd

struct SkyGeometryBuilder {

    let frameData: SkyFrameData

    private(set) var pointVertices: [PointVertex] = []
    private(set) var lineVertices: [LineVertex] = []
    private(set) var projectedObjects: [ProjectedObject] = []
    private(set) var labelCandidates: [SkyLabelCandidate] = []

    /// Glow haloes are accumulated separately and emitted *before* the cores,
    /// so a bright star's core always sits on top of its own bloom.
    private var glowVertices: [PointVertex] = []
    private var coreVertices: [PointVertex] = []

    // "See-through Earth": nothing is culled for being below the horizon any
    // more. An object is hidden *only* when it falls inside the opaque terrain
    // band at its own azimuth (see `TerrainProfile`); everything underneath
    // keeps rendering in its true position, dimmed to match the dimmed
    // background the shader paints there.

    init(frameData: SkyFrameData) {
        self.frameData = frameData
    }

    mutating func run() {
        buildStars()
        buildLines()
        buildDeepSky()
        buildSolarSystem()
        buildConstellationLabels()
        buildCardinalPoints()

        pointVertices = glowVertices + coreVertices
    }

    // MARK: - Compass points

    /// The eight compass bearings, as (label, azimuth in degrees).
    ///
    /// Azimuth in this app is measured from north increasing eastward — the
    /// standard compass convention, established in
    /// `CoordinateTransformService.horizontal` — so these are simply the
    /// eight-point rose at 45-degree steps.
    ///
    /// These are *true* (geographic) bearings, not magnetic ones: they are
    /// derived from the same horizontal frame as every object in the sky, so
    /// "N" points at the north point of the true horizon, directly below the
    /// celestial pole. A handheld magnetic compass will disagree by the local
    /// magnetic declination (roughly 13 degrees east in the Bay Area), which
    /// is expected and correct — planetarium bearings are always true.
    private static let compassPoints: [(text: String, azimuth: Double)] = [
        ("N", 0), ("NE", 45), ("E", 90), ("SE", 135),
        ("S", 180), ("SW", 225), ("W", 270), ("NW", 315),
    ]

    /// Test seam: the rose is a plain constant, and its correctness is a
    /// property worth asserting rather than eyeballing.
    static var compassPointsForTesting: [(text: String, azimuth: Double)] { compassPoints }

    private mutating func buildCardinalPoints() {
        // Drawn on the true horizon. The four cardinals carry more weight than
        // the intercardinals, which fade out at wide fields so the horizon
        // does not turn into a ribbon of text.
        let fov = frameData.cameraFieldOfViewDegrees
        let intercardinalStrength = Self.fadeIn(value: 110.0 - fov, over: 35.0)

        for point in Self.compassPoints {
            let isCardinal = point.text.count == 1
            let strength = isCardinal ? 0.9 : intercardinalStrength * 0.75
            guard strength > 0.02 else { continue }

            // Placed a fraction of a degree *above* the local skyline rather
            // than at altitude 0, so the marker always sits on the sky side of
            // the rolling-hills silhouette instead of being swallowed by the
            // opaque band where the terrain happens to rise above 0.
            let horizontal = HorizontalCoordinate(
                altitudeDegrees: TerrainProfile.skylineAltitudeDegrees(azimuthDegrees: point.azimuth) + 0.4,
                azimuthDegrees: point.azimuth
            )
            // `applyTerrainOcclusion: false` because the marker is deliberately
            // pinned to the skyline the occlusion test is defined against.
            guard let ndc = project(horizontal: horizontal, applyTerrainOcclusion: false),
                  isOnScreen(ndc, margin: 0.02) else { continue }

            labelCandidates.append(
                SkyLabelCandidate(
                    id: "cardinal-\(point.text)",
                    text: point.text,
                    ndc: CGPoint(x: ndc.x, y: ndc.y),
                    priority: .cardinal,
                    style: .cardinal,
                    strength: strength,
                    // Nudged clear of the skyline so the glyph sits on the sky
                    // side of the silhouette rather than inside the black band.
                    verticalOffsetPoints: -12
                )
            )
        }
    }

    // MARK: - Projection

    /// Projects an equatorial coordinate to viewport NDC, or nil if it is
    /// hidden behind the terrain band / outside the projection's valid region.
    private func project(_ equatorial: EquatorialCoordinate) -> SIMD2<Double>? {
        projectShaded(equatorial)?.ndc
    }

    /// Projection plus the terrain brightness multiplier for the direction.
    ///
    /// One call does both because they need the same horizontal coordinate:
    /// the occlusion test and the dimming are both functions of (altitude,
    /// azimuth), and recomputing the transform for each would double the cost
    /// of the hottest loop in the frame.
    private func projectShaded(
        _ equatorial: EquatorialCoordinate
    ) -> (ndc: SIMD2<Double>, dimming: Double)? {
        let horizontal = CoordinateTransformService.horizontal(
            from: equatorial,
            observer: frameData.observerLocation,
            julianDay: frameData.julianDay
        )
        guard let ndc = project(horizontal: horizontal) else { return nil }
        return (ndc, TerrainProfile.dimming(
            altitudeDegrees: horizontal.altitudeDegrees,
            azimuthDegrees: horizontal.azimuthDegrees
        ))
    }

    /// - Parameter applyTerrainOcclusion: when true (the default) the point is
    ///   rejected if it lies inside the opaque skyline band. Pass false for
    ///   markers that are *meant* to sit on the skyline, and for reference
    ///   directions (the Sun's screen position for the bright-limb angle) that
    ///   must resolve whether or not they are visible.
    private func project(horizontal: HorizontalCoordinate, applyTerrainOcclusion: Bool = true) -> SIMD2<Double>? {
        if applyTerrainOcclusion, TerrainProfile.isOccluded(
            altitudeDegrees: horizontal.altitudeDegrees,
            azimuthDegrees: horizontal.azimuthDegrees
        ) { return nil }
        guard let ndc = CoordinateTransformService.stereographicProject(
            horizontal: horizontal,
            center: frameData.cameraCenter,
            fieldOfViewDegrees: frameData.cameraFieldOfViewDegrees
        ) else { return nil }
        return CoordinateTransformService.aspectCorrected(ndc, viewportSize: frameData.viewportSize)
    }

    /// Generous off-screen margin: sprites and labels whose centre is just
    /// outside the frame can still contribute pixels.
    private func isOnScreen(_ ndc: SIMD2<Double>, margin: Double = 0.15) -> Bool {
        abs(ndc.x) <= 1 + margin && abs(ndc.y) <= 1 + margin
    }

    // MARK: - Stars

    private mutating func buildStars() {
        let fov = frameData.cameraFieldOfViewDegrees
        let sunAltitude = frameData.sunAltitudeDegrees
        // Floored in daylight (see `SkyBrightness.displayLimitingMagnitude`)
        // so the field stays visible through a bright sky, the way a
        // planetarium needs it to be. Positions are unaffected — only how
        // many stars are drawn, and how strongly.
        let magnitudeLimit = StarAppearance.effectiveLimitingMagnitude(
            fieldOfViewDegrees: fov,
            sunAltitudeDegrees: sunAltitude
        )

        // Named/bright stars start earning labels only once you've zoomed in
        // past roughly a "whole constellation" field.
        let starLabelStrength = Self.fadeIn(value: 70.0 - fov, over: 25.0)

        glowVertices.reserveCapacity(256)
        coreVertices.reserveCapacity(2048)
        projectedObjects.reserveCapacity(2048)

        let plan = starScanPlan()
        for range in plan.ranges {
        for i in range {
            let star = plan.stars[i]
            // Magnitude is the cheapest possible rejection, and within a cell
            // the stars are magnitude-ascending, so this ends the cell rather
            // than skipping one star.
            if star.magnitude >= magnitudeLimit { break }

            let baseVisibility = StarAppearance.visibility(
                magnitude: star.magnitude,
                fieldOfViewDegrees: fov,
                sunAltitudeDegrees: sunAltitude
            )
            guard baseVisibility > 0.02 else { continue }

            guard let shaded = projectShaded(star.equatorial) else { continue }
            let ndc = shaded.ndc
            guard isOnScreen(ndc) else { continue }
            // Sub-horizon stars are folded into the same alpha every other
            // brightness factor already multiplies, so they sit consistently
            // with the dimmed background rather than on a parallel path.
            let visibility = baseVisibility * shaded.dimming

            var color = StarAppearance.color(colorIndex: star.colorIndex)
            color.w = Float(visibility)
            let position = SIMD2(Float(ndc.x), Float(ndc.y))

            // Bright stars get a soft halo behind a small bright core; medium
            // and faint stars are just the core.
            if star.magnitude <= StarAppearance.glowMagnitudeThreshold {
                var glowColor = color
                glowColor.w = StarAppearance.glowAlpha(forMagnitude: star.magnitude) * Float(visibility)
                glowVertices.append(
                    PointVertex(
                        positionNDC: position,
                        color: glowColor,
                        pointSize: StarAppearance.glowSize(forMagnitude: star.magnitude),
                        shape: PointSpriteShape.glow.rawValue
                    )
                )
            }

            coreVertices.append(
                PointVertex(
                    positionNDC: position,
                    color: color,
                    pointSize: StarAppearance.pointSize(forMagnitude: star.magnitude),
                    shape: PointSpriteShape.starCore.rawValue
                )
            )

            let object = star.asCelestialObject
            projectedObjects.append(ProjectedObject(object: object, ndcPosition: ndc))

            addStarLabelIfWorthy(
                star: star,
                object: object,
                ndc: ndc,
                fovStrength: starLabelStrength,
                visibility: visibility
            )
        }
        }
    }

    /// Which slices of which star array `buildStars` should walk this frame.
    ///
    /// With a `StarIndex` present this is the spatial cull: the camera centre
    /// is rotated into the equatorial frame (the same matrix the background
    /// shader uses), the viewport's angular radius is derived exactly from the
    /// stereographic projection, and every cell whose bounding cone cannot
    /// reach that cone is dropped without a single star being touched.
    ///
    /// Without an index — catalogue still loading, or a hand-built snapshot in
    /// a test — it degrades to one range covering the whole catalogue, which
    /// produces byte-identical geometry, just slower.
    private func starScanPlan() -> (stars: [Star], ranges: [Range<Int>]) {
        guard let index = frameData.starIndex else {
            return (frameData.stars, frameData.stars.isEmpty ? [] : [0..<frameData.stars.count])
        }

        let theta = StarIndex.fieldAngularRadiusRadians(
            fieldOfViewDegrees: frameData.cameraFieldOfViewDegrees,
            viewportSize: frameData.viewportSize
        )

        // Camera centre as a unit vector in the equatorial Cartesian frame the
        // index is built in.
        let horizontalToEquatorial = SkyBackgroundUniforms.horizontalToEquatorial(
            observer: frameData.observerLocation,
            julianDay: frameData.julianDay
        )
        let centerDirection = simd_normalize(
            horizontalToEquatorial
                * CoordinateTransformService.unitDirection(fromHorizontal: frameData.cameraCenter)
        )

        return (
            index.stars,
            index.visibleCellRanges(centerDirection: centerDirection, angularRadiusRadians: theta)
        )
    }

    private mutating func addStarLabelIfWorthy(
        star: Star,
        object: CelestialObject,
        ndc: SIMD2<Double>,
        fovStrength: Double,
        visibility: Double
    ) {
        // Only stars that a person would actually name: the catalogue's proper
        // names, plus anything genuinely bright.
        guard star.name != nil || star.magnitude <= 1.5 else { return }
        guard isOnScreen(ndc, margin: 0.02) else { return }

        let isSelected = frameData.selectedObjectID == object.id
        // The brighter the star, the earlier its label earns its place.
        let brightnessWeight = Self.fadeIn(value: 3.2 - star.magnitude, over: 2.2)
        let strength = isSelected ? 1.0 : min(1.0, fovStrength * (0.35 + 0.65 * brightnessWeight) * visibility)

        labelCandidates.append(
            SkyLabelCandidate(
                id: object.id,
                text: object.name,
                ndc: CGPoint(x: ndc.x, y: ndc.y),
                priority: isSelected ? .selected : .brightStar,
                style: .star,
                strength: strength
            )
        )
    }

    // MARK: - Constellation lines

    private mutating func buildLines() {
        guard !frameData.starsByID.isEmpty else { return }
        let color = StarAppearance.constellationLineColor(
            fieldOfViewDegrees: frameData.cameraFieldOfViewDegrees
        )
        guard color.w > 0.005 else { return }

        lineVertices.reserveCapacity(frameData.constellationLines.count * 2)

        for segment in frameData.constellationLines {
            guard let s1 = frameData.starsByID[segment.starID1],
                  let s2 = frameData.starsByID[segment.starID2] else { continue }
            guard let e1 = projectShaded(s1.equatorial), let e2 = projectShaded(s2.equatorial) else { continue }
            let ndc1 = e1.ndc, ndc2 = e2.ndc
            // Skip segments that wrap unreasonably far across the screen
            // (projection seam) or that are entirely off-screen.
            if simd_distance(ndc1, ndc2) > 1.5 { continue }
            if !isOnScreen(ndc1, margin: 1.0) && !isOnScreen(ndc2, margin: 1.0) { continue }
            // Dim per endpoint, so a figure straddling the skyline fades along
            // the segment instead of stepping at the crossing.
            var c1 = color, c2 = color
            c1.w *= Float(e1.dimming)
            c2.w *= Float(e2.dimming)
            lineVertices.append(LineVertex(positionNDC: SIMD2(Float(ndc1.x), Float(ndc1.y)), color: c1))
            lineVertices.append(LineVertex(positionNDC: SIMD2(Float(ndc2.x), Float(ndc2.y)), color: c2))
        }
    }

    // MARK: - Constellation labels

    private mutating func buildConstellationLabels() {
        guard !frameData.constellations.isEmpty else { return }
        let fov = frameData.cameraFieldOfViewDegrees
        // Most useful at "one or two constellations on screen" fields: fades
        // out both when the whole sky is visible and at high magnification.
        let wideFade = Self.fadeIn(value: 110.0 - fov, over: 30.0)
        let tightFade = Self.fadeIn(value: fov - 6.0, over: 8.0)
        let strength = wideFade * tightFade * 0.85
        guard strength > 0.05 else { return }

        for constellation in frameData.constellations {
            guard let shaded = projectShaded(constellation.equatorial) else { continue }
            let ndc = shaded.ndc
            guard isOnScreen(ndc, margin: 0.0) else { continue }
            labelCandidates.append(
                SkyLabelCandidate(
                    id: "constellation-\(constellation.name)",
                    text: constellation.name.uppercased(),
                    ndc: CGPoint(x: ndc.x, y: ndc.y),
                    priority: .constellation,
                    style: .constellation,
                    // Sub-horizon constellations are still named, dimmed to
                    // match. Strength feeds the same priority/collision
                    // machinery, so weaker sub-horizon labels lose ties to
                    // above-horizon ones and the band cannot fill with text.
                    strength: strength * shaded.dimming,
                    verticalOffsetPoints: 0
                )
            )
        }
    }

    // MARK: - Deep-sky objects

    /// Galaxies, nebulae and clusters from the bundled OpenNGC-derived
    /// catalogue. Only ~900 entries survive the load-time filter, so this is a
    /// plain linear scan — no spatial index, and it costs less than a single
    /// cell of the star grid.
    ///
    /// The sprites go into `glowVertices`, i.e. the layer drawn *before* the
    /// star cores, so a cluster's real member stars sit on top of its haze
    /// rather than under it.
    private mutating func buildDeepSky() {
        guard !frameData.deepSkyObjects.isEmpty else { return }

        let fov = frameData.cameraFieldOfViewDegrees
        let sunAltitude = frameData.sunAltitudeDegrees
        let viewportWidth = Double(frameData.viewportSize.width)

        // Deep-sky labels start earning their place a little later than star
        // labels: at a whole-sky field only the handful of famous bright
        // objects should be named, or the view becomes a wall of text.
        let labelFOVStrength = Self.fadeIn(value: 80.0 - fov, over: 45.0)

        // Extended objects wash out into twilight sooner than point sources
        // do; see `StarAppearance.deepSkyTwilightFactor`.
        let twilightFactor = StarAppearance.deepSkyTwilightFactor(sunAltitudeDegrees: sunAltitude)
        guard twilightFactor > 0.01 else { return }

        for dso in frameData.deepSkyObjects {
            guard dso.type.isRenderable else { continue }
            let type = dso.renderType

            // Extended objects are governed by the *same* brightness model the
            // stars use — invisible in daylight, emerging as the sky darkens,
            // more of them appearing as you zoom — but with a bounded
            // surface-brightness penalty applied first. See
            // `StarAppearance.deepSkyDetectionMagnitude` for the approximation.
            let detectionMagnitude = StarAppearance.deepSkyDetectionMagnitude(
                magnitude: dso.magnitude,
                majorAxisArcmin: dso.majorAxisArcmin,
                minorAxisArcmin: dso.minorAxisArcmin
            )
            let baseVisibility = StarAppearance.visibility(
                magnitude: detectionMagnitude,
                fieldOfViewDegrees: fov,
                sunAltitudeDegrees: sunAltitude
            ) * twilightFactor
            guard baseVisibility > 0.02 else { continue }

            guard let shaded = projectShaded(dso.equatorial) else { continue }
            let ndc = shaded.ndc
            guard isOnScreen(ndc, margin: 0.35) else { continue }
            // Below the skyline M31 still draws — same position, same
            // orientation, same ellipse — only dimmed.
            let visibility = baseVisibility * shaded.dimming

            let size = StarAppearance.deepSkyPointSize(
                majorAxisArcmin: dso.majorAxisArcmin,
                fieldOfViewDegrees: fov,
                viewportWidth: viewportWidth
            )
            let detail = StarAppearance.detailLevel(pointSize: size)

            // Orientation and elongation. Both need real axis data *and* a
            // position angle: without an angle an elongated blob would point
            // in an arbitrary direction, which is worse than a circle.
            var axisRatio = 1.0
            var screenAngle = 0.0
            if let positionAngle = dso.positionAngleDegrees {
                axisRatio = StarAppearance.deepSkyAxisRatio(
                    majorAxisArcmin: dso.majorAxisArcmin,
                    minorAxisArcmin: dso.minorAxisArcmin
                )
                if axisRatio < 0.999,
                   let angle = majorAxisScreenAngle(
                       equatorial: dso.equatorial,
                       positionAngleDegrees: positionAngle,
                       centerNDC: ndc
                   ) {
                    screenAngle = angle
                } else {
                    axisRatio = 1.0
                }
            }

            var color = StarAppearance.deepSkyColor(type: type)
            color.w = Float(visibility * StarAppearance.deepSkyOpacity(type: type))

            glowVertices.append(
                PointVertex(
                    positionNDC: SIMD2(Float(ndc.x), Float(ndc.y)),
                    color: color,
                    pointSize: size,
                    shape: PointSpriteShape.deepSky.rawValue,
                    param0: Float(axisRatio),
                    param1: Float(screenAngle),
                    param2: detail,
                    param3: StarAppearance.deepSkyShaderCode(type: type)
                )
            )

            let object = dso.asCelestialObject
            projectedObjects.append(ProjectedObject(object: object, ndcPosition: ndc))

            addDeepSkyLabelIfWorthy(
                dso: dso,
                object: object,
                ndc: ndc,
                spriteRadius: Double(size) * 0.5,
                fovStrength: labelFOVStrength,
                visibility: visibility
            )
        }
    }

    private mutating func addDeepSkyLabelIfWorthy(
        dso: DeepSkyObject,
        object: CelestialObject,
        ndc: SIMD2<Double>,
        spriteRadius: Double,
        fovStrength: Double,
        visibility: Double
    ) {
        guard isOnScreen(ndc, margin: 0.02) else { return }

        let isSelected = frameData.selectedObjectID == object.id
        // Only the genuinely famous objects (M31 at 3.4, M45 at 1.2, M42 at
        // 4.0) carry any weight at a wide field; everything fainter needs both
        // zoom and its own brightness to earn a label.
        let brightnessWeight = Self.fadeIn(value: 7.5 - dso.magnitude, over: 4.5)
        let strength = isSelected
            ? 1.0
            : min(1.0, fovStrength * brightnessWeight * brightnessWeight * visibility)

        labelCandidates.append(
            SkyLabelCandidate(
                id: object.id,
                text: object.name,
                ndc: CGPoint(x: ndc.x, y: ndc.y),
                priority: isSelected ? .selected : .deepSky,
                style: .deepSky,
                strength: strength,
                // Clear of the drawn ellipse, the same way solar-system labels
                // clear their disks.
                verticalOffsetPoints: spriteRadius + 12.0
            )
        )
    }

    /// Screen-space direction of an object's major axis, given its position
    /// angle in degrees **east of north**.
    ///
    /// Derived the same way `brightLimbAngle` derives the Moon's terminator
    /// orientation: project a second point offset from the object along the
    /// position angle and take the screen-space direction between the two.
    /// Going through the projection is what keeps the angle correct as the
    /// camera pans and the sky rotates — a closed-form formula would have to
    /// re-derive the local frame's rotation, and this does not.
    private func majorAxisScreenAngle(
        equatorial: EquatorialCoordinate,
        positionAngleDegrees: Double,
        centerNDC: SIMD2<Double>
    ) -> Double? {
        let pa = positionAngleDegrees * .pi / 180.0
        // Small step along the great circle in the direction of the position
        // angle: north is +declination, east is +right ascension (scaled by
        // cos(dec), the usual convergence of the RA lines).
        let delta = 0.05
        let dec = equatorial.declinationDegrees
        let cosDec = max(0.02, cos(dec * .pi / 180.0))
        let offset = EquatorialCoordinate(
            rightAscensionDegrees: equatorial.rightAscensionDegrees + delta * sin(pa) / cosDec,
            declinationDegrees: max(-89.99, min(89.99, dec + delta * cos(pa)))
        )

        let horizontal = CoordinateTransformService.horizontal(
            from: offset, observer: frameData.observerLocation, julianDay: frameData.julianDay
        )
        guard let offsetNDC = project(horizontal: horizontal, applyTerrainOcclusion: false) else { return nil }
        let d = offsetNDC - centerNDC
        guard simd_length(d) > 1e-9 else { return nil }
        return atan2(d.y, d.x)
    }

    // MARK: - Sun, Moon and planets

    private mutating func buildSolarSystem() {
        let fov = frameData.cameraFieldOfViewDegrees
        let viewportWidth = Double(frameData.viewportSize.width)

        // Screen position of the Sun, ignoring terrain occlusion, so the
        // Moon's bright limb still points the right way after sunset.
        let sunScreen: SIMD2<Double>? = frameData.sunEquatorial.flatMap { eq in
            let horizontal = CoordinateTransformService.horizontal(
                from: eq, observer: frameData.observerLocation, julianDay: frameData.julianDay
            )
            return project(horizontal: horizontal, applyTerrainOcclusion: false)
        }

        let sunAltitude = frameData.sunAltitudeDegrees

        for object in frameData.solarSystemObjects {
            guard let shaded = projectShaded(object.equatorial) else { continue }
            let ndc = shaded.ndc
            guard isOnScreen(ndc, margin: 0.25) else { continue }

            // Solar-system bodies are exempt from the magnitude cutoff
            // entirely, at every hour of the day. A planetarium's job is to
            // answer "where is Neptune right now", and Neptune at magnitude
            // 7.8 would otherwise vanish under any daylight or wide-field
            // limit — as would Uranus, and Mercury near superior conjunction.
            // They are still modulated in *contrast* by the sky brightness, so
            // they read as dimmer against a bright sky, but the multiplier
            // bottoms out at `daylightContrastFloor` and never reaches zero.
            // The Sun and Moon skip even that — they *are* the daylight.
            //
            // The terrain dimming is folded in on top: a planet below the
            // skyline is still drawn at its true position, just dimmer, to
            // match the dimmed sky it now sits against.
            let visibility: Double
            switch object.kind {
            case .sun, .moon:
                visibility = shaded.dimming
            default:
                visibility = SkyBrightness.starContrast(sunAltitudeDegrees: sunAltitude) * shaded.dimming
            }

            let position = SIMD2(Float(ndc.x), Float(ndc.y))
            let size = StarAppearance.solarSystemPointSize(
                objectID: object.id,
                kind: object.kind,
                magnitude: object.magnitude,
                distanceKilometres: object.distanceKilometres,
                fieldOfViewDegrees: fov,
                viewportWidth: viewportWidth
            )
            let detail = StarAppearance.detailLevel(pointSize: size)
            let alpha = Float(visibility)

            // Screen-space direction toward the Sun: the bright limb of any
            // phased body points that way. Same construction the Moon has
            // always used, reused unchanged for the inferior planets.
            let limbAngle = Self.brightLimbAngle(moonNDC: ndc, sunNDC: sunScreen)

            /// Radius of the drawn sprite in points, used to push the label
            /// clear of the body.
            var spriteRadius = Double(size) * 0.5

            switch object.kind {
            case .sun:
                // The bloom is a *smooth* minimum of "3.4x the disk" and
                // "a bounded offset from the disk", so it dominates at wide
                // field and then stops growing instead of swallowing the view.
                let glowSize = StarAppearance.smoothMin(
                    Double(size) * 3.4,
                    Double(size) * 1.25 + 110.0,
                    softness: 40.0
                )
                appendGlow(at: position, color: StarAppearance.sunColor,
                           size: Float(glowSize), alpha: 0.40 * alpha)
                var sunColor = StarAppearance.sunColor
                sunColor.w *= alpha
                coreVertices.append(
                    PointVertex(positionNDC: position, color: sunColor,
                                pointSize: size, shape: PointSpriteShape.sunDisk.rawValue,
                                param2: detail)
                )

            case .moon:
                let k = object.illuminatedFraction ?? frameData.moonIlluminatedFraction
                appendGlow(
                    at: position,
                    color: StarAppearance.moonColor,
                    size: size * 2.6,
                    alpha: Float(0.06 + 0.22 * k) * alpha
                )
                var moonColor = StarAppearance.moonColor
                moonColor.w *= alpha
                coreVertices.append(
                    PointVertex(
                        positionNDC: position,
                        color: moonColor,
                        pointSize: size,
                        shape: PointSpriteShape.moon.rawValue,
                        param0: Float(k),
                        param1: Float(limbAngle)
                    )
                )

            case .planet:
                var color = StarAppearance.planetColor(id: object.id)
                color.w = alpha
                var glowColor = color
                glowColor.w = 0.20 * alpha
                glowVertices.append(
                    PointVertex(positionNDC: position, color: glowColor,
                                pointSize: min(200, size * 3.0),
                                shape: PointSpriteShape.glow.rawValue)
                )

                // Saturn's sprite widens to make room for its rings; the
                // shader shrinks the disk inside it by exactly the same
                // factor, so the planet itself is unaffected.
                var spriteSize = size
                if object.id == "saturn" {
                    let scale = StarAppearance.saturnSpriteScale(detail: detail)
                    // Hard cap: Metal point sizes are limited (511 on current
                    // Apple GPUs), and 260 * 2.4 would overshoot it.
                    spriteSize = min(500, size * scale)
                    spriteRadius = Double(spriteSize) * 0.5
                }

                coreVertices.append(
                    PointVertex(
                        positionNDC: position,
                        color: color,
                        pointSize: spriteSize,
                        shape: PointSpriteShape.planetDisk.rawValue,
                        param0: Float(object.illuminatedFraction ?? 1.0),
                        param1: Float(limbAngle),
                        param2: detail,
                        param3: StarAppearance.planetShaderCode(id: object.id)
                    )
                )

            case .star, .deepSky:
                // Deep-sky objects never appear in `solarSystemObjects`; they
                // have their own pass. This branch exists only for exhaustive-
                // ness and draws a plain point.
                var color = StarAppearance.color(colorIndex: nil)
                color.w = alpha
                coreVertices.append(
                    PointVertex(positionNDC: position, color: color,
                                pointSize: size, shape: PointSpriteShape.starCore.rawValue)
                )
            }

            projectedObjects.append(ProjectedObject(object: object, ndcPosition: ndc))

            let isSelected = frameData.selectedObjectID == object.id
            let priority: LabelPriority
            if isSelected {
                priority = .selected
            } else if object.kind == .planet {
                priority = .planet
            } else {
                priority = .luminary
            }
            // Solar-system labels are always worth showing when the body is on
            // screen; only the very faintest outer planets fade at wide field.
            let base = object.magnitude > 5.0 ? Self.fadeIn(value: 45.0 - fov, over: 20.0) : 1.0
            // At extreme zoom the disk fills the view and its name is noise.
            let zoomFade = 1.0 - Self.fadeIn(value: spriteRadius - 110.0, over: 60.0)
            labelCandidates.append(
                SkyLabelCandidate(
                    id: object.id,
                    text: object.name,
                    ndc: CGPoint(x: ndc.x, y: ndc.y),
                    priority: priority,
                    style: .solarSystem,
                    strength: (isSelected ? 1.0 : base * visibility) * zoomFade,
                    // Offset tracks the drawn disk, so a big Jupiter never
                    // covers its own label. 14 pt at marker scale, growing
                    // linearly with the radius after that.
                    verticalOffsetPoints: spriteRadius + 12.0
                )
            )
        }

        appendSelectionRing()
    }

    private mutating func appendGlow(at position: SIMD2<Float>, color: SIMD4<Float>, size: Float, alpha: Float) {
        var glowColor = color
        glowColor.w = alpha
        glowVertices.append(
            PointVertex(positionNDC: position, color: glowColor,
                        pointSize: min(200, size), shape: PointSpriteShape.glow.rawValue)
        )
    }

    private mutating func appendSelectionRing() {
        guard let selectedID = frameData.selectedObjectID,
              let projected = projectedObjects.first(where: { $0.object.id == selectedID }),
              isOnScreen(projected.ndcPosition, margin: 0.02) else { return }

        let baseSize: Float
        switch projected.object.kind {
        case .sun, .moon, .planet:
            // Ring tracks the actual drawn disk, so selecting a zoomed-in
            // planet rings the planet rather than sitting inside it.
            baseSize = StarAppearance.solarSystemPointSize(
                objectID: projected.object.id,
                kind: projected.object.kind,
                magnitude: projected.object.magnitude,
                distanceKilometres: projected.object.distanceKilometres,
                fieldOfViewDegrees: frameData.cameraFieldOfViewDegrees,
                viewportWidth: Double(frameData.viewportSize.width)
            ) * 1.9
        case .star:
            baseSize = max(26, StarAppearance.pointSize(forMagnitude: projected.object.magnitude) * 3.2)
        case .deepSky:
            // Ring the drawn ellipse, not a fixed marker, so selecting a
            // zoomed-in M31 rings the galaxy.
            baseSize = StarAppearance.deepSkyPointSize(
                majorAxisArcmin: projected.object.majorAxisArcmin,
                fieldOfViewDegrees: frameData.cameraFieldOfViewDegrees,
                viewportWidth: Double(frameData.viewportSize.width)
            ) * 1.15
        }

        coreVertices.append(
            PointVertex(
                positionNDC: SIMD2(Float(projected.ndcPosition.x), Float(projected.ndcPosition.y)),
                color: StarAppearance.selectionRingColor,
                pointSize: min(500, max(22, baseSize)),
                shape: PointSpriteShape.selectionRing.rawValue
            )
        )
    }

    // MARK: - Helpers

    /// Screen-space position angle of the Moon's bright limb: simply the
    /// direction from the Moon toward the Sun on screen. Exact enough for a
    /// disk a few tens of pixels across, and it stays correct as the camera
    /// rotates because both endpoints go through the same projection.
    static func brightLimbAngle(moonNDC: SIMD2<Double>, sunNDC: SIMD2<Double>?) -> Double {
        guard let sunNDC else { return 0 }
        let d = sunNDC - moonNDC
        guard simd_length(d) > 1e-9 else { return 0 }
        return atan2(d.y, d.x)
    }

    /// 0 below zero, smoothly rising to 1 once `value` exceeds `over`.
    static func fadeIn(value: Double, over width: Double) -> Double {
        guard width > 0 else { return value > 0 ? 1 : 0 }
        let t = min(1.0, max(0.0, value / width))
        return t * t * (3 - 2 * t)
    }
}

extension Star {
    var equatorial: EquatorialCoordinate {
        EquatorialCoordinate(rightAscensionDegrees: ra, declinationDegrees: dec)
    }
}
