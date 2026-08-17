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
//  Cost per frame is one pass over the ~5k-star catalogue. Faint stars are
//  rejected by an integer magnitude comparison *before* any trigonometry
//  (see `StarAppearance.limitingMagnitude`), so at wide fields — where the
//  most stars are on screen — the trig is only run for the few hundred stars
//  that actually get drawn. That is what keeps 60-120 Hz panning affordable.
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

    /// Below-horizon objects are culled with a small margin so bodies right on
    /// the horizon don't blink out.
    private static let horizonMarginDegrees = -2.0

    init(frameData: SkyFrameData) {
        self.frameData = frameData
    }

    mutating func run() {
        buildStars()
        buildLines()
        buildSolarSystem()
        buildConstellationLabels()

        pointVertices = glowVertices + coreVertices
    }

    // MARK: - Projection

    /// Projects an equatorial coordinate to viewport NDC, or nil if it is
    /// below the horizon / outside the projection's valid region.
    private func project(_ equatorial: EquatorialCoordinate) -> SIMD2<Double>? {
        let horizontal = CoordinateTransformService.horizontal(
            from: equatorial,
            observer: frameData.observerLocation,
            julianDay: frameData.julianDay
        )
        return project(horizontal: horizontal)
    }

    private func project(horizontal: HorizontalCoordinate, cullBelowHorizon: Bool = true) -> SIMD2<Double>? {
        if cullBelowHorizon, horizontal.altitudeDegrees < Self.horizonMarginDegrees { return nil }
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
        let magnitudeLimit = StarAppearance.limitingMagnitude(fieldOfViewDegrees: fov)

        // Named/bright stars start earning labels only once you've zoomed in
        // past roughly a "whole constellation" field.
        let starLabelStrength = Self.fadeIn(value: 70.0 - fov, over: 25.0)

        glowVertices.reserveCapacity(256)
        coreVertices.reserveCapacity(2048)
        projectedObjects.reserveCapacity(2048)

        for star in frameData.stars {
            // CPU-side magnitude cutoff before any trigonometry.
            guard star.magnitude < magnitudeLimit else { continue }
            let visibility = StarAppearance.visibility(magnitude: star.magnitude, fieldOfViewDegrees: fov)
            guard visibility > 0.02 else { continue }

            guard let ndc = project(star.equatorial), isOnScreen(ndc) else { continue }

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
            guard let ndc1 = project(s1.equatorial), let ndc2 = project(s2.equatorial) else { continue }
            // Skip segments that wrap unreasonably far across the screen
            // (projection seam) or that are entirely off-screen.
            if simd_distance(ndc1, ndc2) > 1.5 { continue }
            if !isOnScreen(ndc1, margin: 1.0) && !isOnScreen(ndc2, margin: 1.0) { continue }
            lineVertices.append(LineVertex(positionNDC: SIMD2(Float(ndc1.x), Float(ndc1.y)), color: color))
            lineVertices.append(LineVertex(positionNDC: SIMD2(Float(ndc2.x), Float(ndc2.y)), color: color))
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
            guard let ndc = project(constellation.equatorial), isOnScreen(ndc, margin: 0.0) else { continue }
            labelCandidates.append(
                SkyLabelCandidate(
                    id: "constellation-\(constellation.name)",
                    text: constellation.name.uppercased(),
                    ndc: CGPoint(x: ndc.x, y: ndc.y),
                    priority: .constellation,
                    style: .constellation,
                    strength: strength
                )
            )
        }
    }

    // MARK: - Sun, Moon and planets

    private mutating func buildSolarSystem() {
        let fov = frameData.cameraFieldOfViewDegrees
        let viewportWidth = Double(frameData.viewportSize.width)

        // Screen position of the Sun, ignoring the horizon cull, so the Moon's
        // bright limb still points the right way after sunset.
        let sunScreen: SIMD2<Double>? = frameData.sunEquatorial.flatMap { eq in
            let horizontal = CoordinateTransformService.horizontal(
                from: eq, observer: frameData.observerLocation, julianDay: frameData.julianDay
            )
            return project(horizontal: horizontal, cullBelowHorizon: false)
        }

        for object in frameData.solarSystemObjects {
            guard let ndc = project(object.equatorial), isOnScreen(ndc, margin: 0.25) else { continue }
            let position = SIMD2(Float(ndc.x), Float(ndc.y))
            let size = StarAppearance.solarSystemPointSize(
                kind: object.kind,
                magnitude: object.magnitude,
                fieldOfViewDegrees: fov,
                viewportWidth: viewportWidth
            )

            switch object.kind {
            case .sun:
                appendGlow(at: position, color: StarAppearance.sunColor, size: size * 3.4, alpha: 0.40)
                coreVertices.append(
                    PointVertex(positionNDC: position, color: StarAppearance.sunColor,
                                pointSize: size, shape: PointSpriteShape.disk.rawValue)
                )

            case .moon:
                let k = frameData.moonIlluminatedFraction
                appendGlow(
                    at: position,
                    color: StarAppearance.moonColor,
                    size: size * 2.6,
                    alpha: Float(0.06 + 0.22 * k)
                )
                let limbAngle = Self.brightLimbAngle(moonNDC: ndc, sunNDC: sunScreen)
                coreVertices.append(
                    PointVertex(
                        positionNDC: position,
                        color: StarAppearance.moonColor,
                        pointSize: size,
                        shape: PointSpriteShape.moon.rawValue,
                        param0: Float(k),
                        param1: Float(limbAngle)
                    )
                )

            case .planet:
                let color = StarAppearance.planetColor(id: object.id)
                appendGlow(at: position, color: color, size: size * 3.0, alpha: 0.20)
                coreVertices.append(
                    PointVertex(positionNDC: position, color: color,
                                pointSize: size, shape: PointSpriteShape.disk.rawValue)
                )

            case .star:
                coreVertices.append(
                    PointVertex(positionNDC: position, color: StarAppearance.color(colorIndex: nil),
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
            labelCandidates.append(
                SkyLabelCandidate(
                    id: object.id,
                    text: object.name,
                    ndc: CGPoint(x: ndc.x, y: ndc.y),
                    priority: priority,
                    style: .solarSystem,
                    strength: isSelected ? 1.0 : base
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
        case .sun, .moon:
            baseSize = StarAppearance.solarSystemPointSize(
                kind: projected.object.kind,
                magnitude: projected.object.magnitude,
                fieldOfViewDegrees: frameData.cameraFieldOfViewDegrees,
                viewportWidth: Double(frameData.viewportSize.width)
            ) * 1.9
        default:
            baseSize = max(26, StarAppearance.pointSize(forMagnitude: projected.object.magnitude) * 3.2)
        }

        coreVertices.append(
            PointVertex(
                positionNDC: SIMD2(Float(projected.ndcPosition.x), Float(projected.ndcPosition.y)),
                color: StarAppearance.selectionRingColor,
                pointSize: min(180, max(22, baseSize)),
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
