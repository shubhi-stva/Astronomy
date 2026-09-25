//
//  SkyExtrasBuilder.swift
//  Astronomy
//
//  The Galilean moons and the active meteor-shower radiants: two small layers
//  that hang off the solar-system pass.
//

import CoreGraphics
import Foundation
import simd

extension SkyGeometryBuilder {

    // MARK: - Jupiter's moons

    /// Io, Europa, Ganymede and Callisto around Jupiter.
    ///
    /// Drawn only once the field is narrow enough for them to separate from
    /// the planet's sprite — at a 90° field all four sit inside Jupiter's
    /// marker — and faded in over the zoom so they never pop. A moon behind
    /// the disk is skipped; one in transit is drawn over it, which is what a
    /// telescope shows.
    mutating func buildJupiterMoons() {
        guard frameData.planetMoonsEnabled,
              let jupiter = frameData.solarSystemObjects.first(where: { $0.id == "jupiter" }),
              let distanceKm = jupiter.distanceKilometres else { return }
        let fov = frameData.cameraFieldOfViewDegrees
        let zoomStrength = Self.fadeIn(value: 12.0 - fov, over: 8.0)
        guard zoomStrength > 0.02 else { return }
        let projector = self.projector
        guard let jupiterNDC = projector.project(direction: projector.direction(ofDate: jupiter.equatorial)),
              isOnScreen(jupiterNDC, margin: 0.5) else { return }

        guard let orientation = PlanetaryOrientation.orientation(
                  objectID: "jupiter", equatorial: jupiter.equatorial, julianDay: frameData.julianDay
              ),
              let poleAngle = PlanetaryOrientation.polePositionAngleDegrees(
                  poleDirection: orientation.poleDirection, equatorial: jupiter.equatorial
              ) else { return }

        let skyContrast = SkyBrightness.starContrast(sunAltitudeDegrees: frameData.sunAltitudeDegrees)
        let labelStrength = Self.fadeIn(value: 3.0 - fov, over: 2.5)
        let positions = JupiterMoons.positions(julianDay: frameData.julianDay)

        for position in positions where !position.isOcculted {
            let equatorial = JupiterMoons.equatorial(
                of: position, jupiter: jupiter.equatorial, jupiterDistanceKm: distanceKm,
                polePositionAngleDegrees: poleAngle
            )
            let direction = projector.direction(ofDate: equatorial)
            guard let ndc = projector.project(direction: direction), isOnScreen(ndc) else { continue }
            let horizontal = projector.horizontal(direction: direction)
            let dimming = TerrainProfile.dimming(
                altitudeDegrees: horizontal.altitudeDegrees, azimuthDegrees: horizontal.azimuthDegrees
            )
            let visibility = zoomStrength * dimming * skyContrast
            guard visibility > 0.02 else { continue }

            var color = SIMD4<Float>(0.96, 0.92, 0.82, 1.0)
            color.w = Float(visibility)
            let size = StarAppearance.pointSize(forMagnitude: position.moon.magnitude) * 1.1
            pointVerticesAppend(PointVertex(
                positionNDC: SIMD2(Float(ndc.x), Float(ndc.y)), color: color,
                pointSize: size, shape: PointSpriteShape.starCore.rawValue
            ))

            var object = CelestialObject(
                id: position.moon.objectID, name: position.moon.name, kind: .planetMoon,
                equatorial: equatorial, magnitude: position.moon.magnitude
            )
            object.distanceKilometres = distanceKm
            projectedObjectsAppend(ProjectedObject(object: object, ndcPosition: ndc))

            let isSelected = frameData.selectedObjectID == object.id
            guard isSelected || labelStrength > 0.02, isOnScreen(ndc, margin: 0.02) else { continue }
            labelCandidatesAppend(SkyLabelCandidate(
                id: object.id, text: position.moon.name,
                ndc: CGPoint(x: ndc.x, y: ndc.y),
                priority: isSelected ? .selected : .satellite, style: .star,
                strength: isSelected ? 1.0 : labelStrength * visibility, verticalOffsetPoints: 10
            ))
        }
    }

    // MARK: - Meteor shower radiants

    /// The radiants of the showers active on the displayed date, as a soft
    /// marker with the shower's name — where the meteors will appear to come
    /// from, which is the one thing a meteor observer wants to know.
    mutating func buildMeteorRadiants() {
        guard frameData.meteorRadiantsEnabled else { return }
        let sunLongitude = EclipticLongitude.sunJ2000(julianDay: frameData.julianDay)
        let active = MeteorShowers.active(solarLongitudeJ2000: sunLongitude)
        guard !active.isEmpty else { return }
        let projector = self.projector
        let fov = frameData.cameraFieldOfViewDegrees
        let zoomFade = 1.0 - Self.fadeIn(value: 4.0 - fov, over: 3.0)
        let twilight = StarAppearance.deepSkyTwilightFactor(sunAltitudeDegrees: frameData.sunAltitudeDegrees)
        guard zoomFade > 0.02, twilight > 0.02 else { return }
        let pointsPerDegree = Double(frameData.viewportSize.width) / max(fov, 0.01)

        for (shower, strength) in active {
            let direction = projector.direction(j2000: shower.radiant)
            guard let ndc = projector.project(direction: direction), isOnScreen(ndc, margin: 0.1) else { continue }
            let horizontal = projector.horizontal(direction: direction)
            let dimming = TerrainProfile.dimming(
                altitudeDegrees: horizontal.altitudeDegrees, azimuthDegrees: horizontal.azimuthDegrees
            )
            let visibility = strength * dimming * twilight * zoomFade
            guard visibility > 0.02 else { continue }
            // A radiant is a few degrees across in practice; the halo is sized
            // to about three degrees, floored so it stays visible at a wide field.
            let size = Float(min(200.0, max(22.0, 3.0 * pointsPerDegree)))
            var color = SIMD4<Float>(0.55, 0.85, 0.75, 1.0)
            color.w = Float(0.35 * visibility)
            pointVerticesAppend(PointVertex(
                positionNDC: SIMD2(Float(ndc.x), Float(ndc.y)), color: color,
                pointSize: size, shape: PointSpriteShape.glow.rawValue
            ))
            labelCandidatesAppend(SkyLabelCandidate(
                id: "radiant-\(shower.id)", text: shower.name.uppercased(),
                ndc: CGPoint(x: ndc.x, y: ndc.y), priority: .constellation, style: .constellation,
                strength: 0.9 * visibility, verticalOffsetPoints: Double(size) * 0.5 + 8
            ))
        }
    }

    // MARK: - Saturn's rings

    /// Ring opening angle and screen orientation for Saturn, as the two
    /// shader parameters the ring branch reads: the sine of the tilt B (the
    /// foreshortening of the ring ellipse) and the screen angle of the ring
    /// axis. Nil if the geometry cannot be formed.
    func saturnRingParameters(
        for object: CelestialObject, centerNDC: SIMD2<Double>
    ) -> (tiltSine: Float, axisScreenAngle: Float)? {
        guard let orientation = PlanetaryOrientation.orientation(
                  objectID: "saturn", equatorial: object.equatorial, julianDay: frameData.julianDay
              ),
              let positionAngle = PlanetaryOrientation.polePositionAngleDegrees(
                  poleDirection: orientation.poleDirection, equatorial: object.equatorial
              ),
              let screenAngle = majorAxisScreenAngle(
                  equatorial: object.equatorial, positionAngleDegrees: positionAngle,
                  centerNDC: centerNDC, precess: false
              ) else { return nil }
        return (
            Float(sin(Angle.degreesToRadians(orientation.subEarthLatitudeDegrees))),
            Float(screenAngle)
        )
    }
}
