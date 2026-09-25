//
//  SkyGridBuilder.swift
//  Astronomy
//
//  The equatorial coordinate grid: parallels of declination and meridians of
//  right ascension, drawn as polylines in the existing line pass.
//
//  Off by default, and reached from the command palette. A grid is a reference
//  overlay, not scenery: it is what turns "that bright star" into "that bright
//  star at +38 degrees", and it is also the fastest way to make a beautiful sky
//  look like a diagram, so it stays out of the way until asked for.
//
//  Three choices worth stating:
//
//   * **Equatorial rather than horizontal.** The app's catalogues, its info
//     panel, its search and its sky paths all speak RA/Dec, and a grid whose
//     lines did not match the numbers next to them would be a second coordinate
//     system for the user to reconcile. The horizon already has its own
//     reference marks — the compass rose and the terrain.
//   * **It rides the existing line buffer.** Like the sky paths before it, the
//     grid costs no extra pass, pipeline state or draw call: it appends to
//     `lineVertices` and is rasterised with the constellation figures.
//   * **It is drawn first.** Emitted before the constellation figures so those
//     overdraw it, which is the correct depth ordering for a reference layer.
//
//  Cost: at most 12 parallels and 24 meridians sampled every 2 degrees, and
//  every sample is rejected before it becomes geometry unless it is near the
//  screen. Measured in `RenderPerformanceTests`.
//

import Foundation
import simd

extension SkyGeometryBuilder {

    /// Sampling step along each grid line, in degrees. Two degrees keeps a
    /// great circle visually smooth at the app's narrowest field (0.5 degrees
    /// across) because at that zoom only one or two samples are on screen and
    /// the segment between them is far longer than the viewport — the curve is
    /// carried by the projection, not by the sampling.
    static let gridSampleStepDegrees: Double = 2.0

    /// Declinations that get a parallel, in degrees. Every 15 — one hour of the
    /// equivalent RA spacing — with the poles excluded, where a parallel
    /// degenerates to a point.
    static let gridParallelDeclinations: [Double] = stride(from: -75.0, through: 75.0, by: 15.0).map { $0 }

    /// Right ascensions that get a meridian, in degrees: one per hour.
    static let gridMeridianRightAscensions: [Double] = stride(from: 0.0, to: 360.0, by: 15.0).map { $0 }

    /// Base grid colour. Cool, dim and well under the constellation figures'
    /// weight — the same family as `StarAppearance.constellationLineColor`, one
    /// step quieter, because a reference line must never compete with a figure.
    static let gridColor = SIMD4<Float>(0.34, 0.44, 0.60, 0.30)

    /// The celestial equator and the zero-hour meridian are drawn brighter:
    /// they are the origins of the system, and without them a grid is a mesh
    /// with no landmarks in it.
    static let gridPrincipalColor = SIMD4<Float>(0.46, 0.60, 0.82, 0.46)

    /// Horizon grid colour: warmer than the equatorial grid so the two are
    /// never confused when both are on.
    static let horizonGridColor = SIMD4<Float>(0.58, 0.50, 0.36, 0.28)
    static let horizonPrincipalColor = SIMD4<Float>(0.80, 0.68, 0.46, 0.46)
    /// The ecliptic: the Sun's own colour family, dim.
    static let eclipticColor = SIMD4<Float>(0.88, 0.72, 0.40, 0.50)
    static let meridianColor = SIMD4<Float>(0.70, 0.60, 0.85, 0.40)
    static let boundaryColor = SIMD4<Float>(0.62, 0.52, 0.42, 0.34)
    static let fieldCircleColor = SIMD4<Float>(0.95, 0.55, 0.35, 0.70)
    static let measureColor = SIMD4<Float>(0.40, 0.95, 0.75, 0.85)

    /// Every reference line the frame asks for. Order is depth order: the
    /// grids first, then the ecliptic and meridian, then boundaries, and the
    /// two tool overlays last so they read on top of everything.
    mutating func buildReferenceLines() {
        buildEquatorialGrid()
        buildHorizontalGrid()
        buildEcliptic()
        buildMeridian()
        buildConstellationBoundaries()
        buildFieldOfViewCircles()
        buildMeasureLine()
    }

    mutating func buildEquatorialGrid() {
        let projector = self.projector
        guard frameData.equatorialGridEnabled else { return }

        for declination in Self.gridParallelDeclinations {
            let isEquator = abs(declination) < 1e-9
            appendGridLine(
                color: isEquator ? Self.gridPrincipalColor : Self.gridColor,
                closed: true,
                sampleCount: Int(360.0 / Self.gridSampleStepDegrees)
            ) { index in
                projector.direction(ofDate: EquatorialCoordinate(
                    rightAscensionDegrees: Double(index) * Self.gridSampleStepDegrees,
                    declinationDegrees: declination
                ))
            }
        }

        for rightAscension in Self.gridMeridianRightAscensions {
            let isPrime = abs(rightAscension) < 1e-9
            // Pole to pole, one open polyline. Not closed: the continuation on
            // the far side of the sphere is a different meridian.
            let steps = Int(180.0 / Self.gridSampleStepDegrees)
            appendGridLine(
                color: isPrime ? Self.gridPrincipalColor : Self.gridColor,
                closed: false,
                sampleCount: steps + 1
            ) { index in
                projector.direction(ofDate: EquatorialCoordinate(
                    rightAscensionDegrees: rightAscension,
                    declinationDegrees: -90 + Double(index) * Self.gridSampleStepDegrees
                ))
            }
        }
    }

    /// Altitude parallels every 15° and azimuth meridians every 30°, with the
    /// true horizon drawn as the principal line. Geometric, not refracted: the
    /// grid is the frame the info panel's altitude is quoted in.
    mutating func buildHorizontalGrid() {
        guard frameData.horizontalGridEnabled else { return }
        for altitude in stride(from: -75.0, through: 75.0, by: 15.0) {
            let isHorizon = abs(altitude) < 1e-9
            appendGridLine(
                color: isHorizon ? Self.horizonPrincipalColor : Self.horizonGridColor,
                closed: true, sampleCount: Int(360.0 / Self.gridSampleStepDegrees)
            ) { index in
                CoordinateTransformService.unitDirection(fromHorizontal: HorizontalCoordinate(
                    altitudeDegrees: altitude, azimuthDegrees: Double(index) * Self.gridSampleStepDegrees
                ))
            }
        }
        for azimuth in stride(from: 0.0, to: 360.0, by: 30.0) {
            let steps = Int(180.0 / Self.gridSampleStepDegrees)
            appendGridLine(
                color: Self.horizonGridColor, closed: false, sampleCount: steps + 1
            ) { index in
                CoordinateTransformService.unitDirection(fromHorizontal: HorizontalCoordinate(
                    altitudeDegrees: -90 + Double(index) * Self.gridSampleStepDegrees, azimuthDegrees: azimuth
                ))
            }
        }
    }

    /// The ecliptic of date: the great circle the Sun travels and the planets
    /// keep close to.
    mutating func buildEcliptic() {
        let projector = self.projector
        guard frameData.eclipticEnabled else { return }
        let toEquatorial = self.apparentFrame.earth.eclipticToEquatorial
        appendGridLine(
            color: Self.eclipticColor, closed: true, sampleCount: Int(360.0 / Self.gridSampleStepDegrees)
        ) { index in
            let lambda = Angle.degreesToRadians(Double(index) * Self.gridSampleStepDegrees)
            let ecliptic = SIMD3(cos(lambda), sin(lambda), 0)
            return projector.apparent(projector.ofDateToHorizontal * (toEquatorial * ecliptic))
        }
        // A few longitude ticks as labels, every 30°, so the line reads as a
        // scale rather than an anonymous arc.
        for degrees in stride(from: 0, to: 360, by: 30) {
            let lambda = Angle.degreesToRadians(Double(degrees))
            let direction = projector.apparent(projector.ofDateToHorizontal * (toEquatorial * SIMD3(cos(lambda), sin(lambda), 0)))
            guard let ndc = projector.project(direction: direction), isOnScreen(ndc, margin: 0.0) else { continue }
            let horizontal = projector.horizontal(direction: direction)
            let dimming = TerrainProfile.dimming(altitudeDegrees: horizontal.altitudeDegrees, azimuthDegrees: horizontal.azimuthDegrees)
            labelCandidates.append(SkyLabelCandidate(
                id: "ecliptic-\(degrees)", text: "λ \(degrees)°",
                ndc: CGPoint(x: ndc.x, y: ndc.y), priority: .cardinal, style: .satellite,
                strength: 0.55 * dimming * Self.fadeIn(value: 100.0 - frameData.cameraFieldOfViewDegrees, over: 40.0),
                verticalOffsetPoints: 9
            ))
        }
    }

    /// The observer's meridian: the north-zenith-south great circle, where
    /// everything culminates.
    mutating func buildMeridian() {
        guard frameData.meridianEnabled else { return }
        let steps = Int(360.0 / Self.gridSampleStepDegrees)
        appendGridLine(color: Self.meridianColor, closed: true, sampleCount: steps) { index in
            // Parametrised by angle from the north point, through the zenith.
            let angle = Angle.degreesToRadians(Double(index) * Self.gridSampleStepDegrees)
            return SIMD3(0, sin(angle), -cos(angle))
        }
    }

    /// The IAU boundaries, culled a polygon at a time by bounding cone.
    mutating func buildConstellationBoundaries() {
        let projector = self.projector
        guard frameData.constellationBoundariesEnabled,
              let boundaries = frameData.constellationBoundaries else { return }
        let fieldRadius = StarIndex.fieldAngularRadiusRadians(
            fieldOfViewDegrees: frameData.cameraFieldOfViewDegrees, viewportSize: frameData.viewportSize
        )
        // Camera centre back in the J2000 frame: the projector's rotation is
        // orthonormal, so its transpose is its inverse.
        let centerJ2000 = projector.j2000ToHorizontal.transpose * projector.centerDirection
        for edge in boundaries.edges {
            let separation = acos(max(-1, min(1, simd_dot(centerJ2000, edge.coneAxis))))
            guard separation <= fieldRadius + edge.coneRadius + 0.02 else { continue }
            // Open, not closed: an edge is a segment of the boundary, not a
            // ring. The ring is what the neighbouring edges add up to.
            appendGridLine(
                color: Self.boundaryColor, closed: false, sampleCount: edge.directions.count
            ) { index in
                projector.direction(j2000Unit: edge.directions[index])
            }
        }
    }

    /// Eyepiece / binocular field circles, centred on the view. A screen
    /// reticle, so not refracted and not dimmed by terrain.
    mutating func buildFieldOfViewCircles() {
        guard !frameData.fieldOfViewCirclesDegrees.isEmpty else { return }
        let center = projector.centerDirection
        let right = projector.right, up = projector.up
        for field in frameData.fieldOfViewCirclesDegrees {
            let rho = Angle.degreesToRadians(field / 2)
            let sampleCount = 180
            var previous: SIMD2<Double>?
            var first: SIMD2<Double>?
            for index in 0...sampleCount {
                let theta = Double(index % sampleCount) / Double(sampleCount) * 2 * .pi
                let direction = cos(rho) * center + sin(rho) * (cos(theta) * right + sin(theta) * up)
                guard let ndc = projector.project(direction: direction) else { previous = nil; continue }
                if first == nil { first = ndc }
                defer { previous = ndc }
                guard let start = previous else { continue }
                appendGridSegment((start, Self.fieldCircleColor.w), (ndc, Self.fieldCircleColor.w), color: Self.fieldCircleColor)
            }
            let top = cos(rho) * center + sin(rho) * up
            if let ndc = projector.project(direction: top), isOnScreen(ndc, margin: 0.0) {
                labelCandidates.append(SkyLabelCandidate(
                    id: "fov-\(field)", text: "\(field.formatted(.number.precision(.fractionLength(0...2))))° field",
                    ndc: CGPoint(x: ndc.x, y: ndc.y), priority: .selected, style: .satellite,
                    strength: 0.9, verticalOffsetPoints: -10
                ))
            }
        }
    }

    /// The angular-distance tool: a great-circle arc between the two measured
    /// objects, labelled at its midpoint.
    mutating func buildMeasureLine() {
        let projector = self.projector
        let endpoints = frameData.measureEndpoints
        guard let firstPoint = endpoints.first else { return }
        let a = projector.ofDateToHorizontal * SkyProjector.unitVector(firstPoint)
        guard endpoints.count == 2 else {
            // Armed but no second point yet: a small ring on the anchor says so.
            if let ndc = projector.project(direction: projector.apparent(a)) {
                pointVerticesAppend(PointVertex(
                    positionNDC: SIMD2(Float(ndc.x), Float(ndc.y)), color: Self.measureColor,
                    pointSize: 34, shape: PointSpriteShape.selectionRing.rawValue
                ))
            }
            return
        }
        let b = projector.ofDateToHorizontal * SkyProjector.unitVector(endpoints[1])
        let omega = acos(max(-1, min(1, simd_dot(a, b))))
        guard omega > 1e-7 else { return }
        let sampleCount = max(8, Int(omega / Angle.degreesToRadians(0.5)))
        appendGridLine(color: Self.measureColor, closed: false, sampleCount: sampleCount + 1) { index in
            let t = Double(index) / Double(sampleCount)
            let v = (sin((1 - t) * omega) * a + sin(t * omega) * b) / sin(omega)
            return projector.apparent(simd_normalize(v))
        }
        let midpoint = projector.apparent(simd_normalize(a + b))
        if let ndc = projector.project(direction: midpoint), isOnScreen(ndc, margin: 0.0) {
            labelCandidates.append(SkyLabelCandidate(
                id: "measure", text: AngularSeparation.formatted(degrees: Angle.radiansToDegrees(omega)),
                ndc: CGPoint(x: ndc.x, y: ndc.y), priority: .selected, style: .satellite,
                strength: 1.0, verticalOffsetPoints: -12
            ))
        }
    }

    /// Projects a sampled curve and appends the segments that survive.
    ///
    /// The grid is a set of *of-date* directions, not catalogue places: a
    /// parallel of declination is defined against the observer's own celestial
    /// equator at the displayed instant, so it must not be precessed. Precessing
    /// it would draw the J2000 grid, which by 2026 is a third of a degree away
    /// from the coordinates the info panel prints.
    private mutating func appendGridLine(
        color: SIMD4<Float>,
        closed: Bool,
        sampleCount: Int,
        direction: (Int) -> SIMD3<Double>
    ) {
        var previous: (ndc: SIMD2<Double>, alpha: Float)?
        var first: (ndc: SIMD2<Double>, alpha: Float)?

        for index in 0..<sampleCount {
            let d = direction(index)
            guard let ndc = projector.project(direction: d) else {
                previous = nil
                continue
            }
            let horizontal = projector.horizontal(direction: d)
            let alpha = color.w * Float(
                TerrainProfile.dimming(
                    altitudeDegrees: horizontal.altitudeDegrees,
                    azimuthDegrees: horizontal.azimuthDegrees
                )
            )
            let point = (ndc: ndc, alpha: alpha)
            if first == nil { first = point }
            defer { previous = point }
            guard let start = previous else { continue }
            appendGridSegment(start, point, color: color)
        }

        // Close a parallel across its seam so it does not have a visible gap at
        // RA 0 when that part of the circle is on screen.
        if closed, let start = previous, let end = first {
            appendGridSegment(start, end, color: color)
        }
    }

    private mutating func appendGridSegment(
        _ start: (ndc: SIMD2<Double>, alpha: Float),
        _ end: (ndc: SIMD2<Double>, alpha: Float),
        color: SIMD4<Float>
    ) {
        // The same two rejections the constellation figures use: a segment that
        // wraps most of the way across the screen is a projection artefact
        // rather than a line, and a segment entirely off-screen is free to drop.
        if simd_distance(start.ndc, end.ndc) > 1.5 { return }
        if !isOnScreen(start.ndc, margin: 1.0) && !isOnScreen(end.ndc, margin: 1.0) { return }
        if start.alpha <= 0.004 && end.alpha <= 0.004 { return }

        var c1 = color
        c1.w = start.alpha
        var c2 = color
        c2.w = end.alpha
        lineVertices.append(
            LineVertex(positionNDC: SIMD2(Float(start.ndc.x), Float(start.ndc.y)), color: c1)
        )
        lineVertices.append(
            LineVertex(positionNDC: SIMD2(Float(end.ndc.x), Float(end.ndc.y)), color: c2)
        )
    }
}
