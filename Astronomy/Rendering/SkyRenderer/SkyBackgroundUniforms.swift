//
//  SkyBackgroundUniforms.swift
//  Astronomy
//
//  Builds the uniform block for the full-screen background pass (horizon /
//  atmosphere gradient + procedural Milky Way).
//
//  Architecture note: rather than approximating the horizon with a
//  screen-space "distance from a horizon line" gradient, the background
//  fragment shader *inverts* the stereographic projection per pixel. That is
//  only a handful of trig ops, and it stays exactly consistent with the star
//  projection at any camera orientation — including looking straight up, where
//  a screen-space horizon line degenerates. All the per-frame work is folded
//  into two 3x3 rotation matrices computed here on the CPU:
//
//    * `cameraToHorizontal` — camera-local (right, up, forward) to the
//      horizontal frame (X = East, Y = Zenith, Z = South). Gives altitude
//      directly as asin(y).
//    * `cameraToGalactic`  — camera-local straight through to galactic
//      coordinates, so the shader gets sin(b) and l for the Milky Way with a
//      single matrix multiply.
//

import CoreGraphics
import Foundation
import simd

/// Must match `BackgroundUniforms` in Shaders.metal field-for-field.
struct SkyBackgroundUniforms {
    var cameraToHorizontal: simd_float3x3
    var cameraToGalactic: simd_float3x3
    /// Y scale applied by `CoordinateTransformService.aspectCorrected`; the
    /// shader divides by it to recover square projection space.
    var aspectScaleY: Float
    /// Tangent-plane units per NDC unit for the current field of view.
    var edgeScale: Float
    /// Sun altitude in degrees; drives the day/twilight/night interpolation.
    var sunAltitudeDegrees: Float
    /// Sun azimuth in degrees; positions the warm glow along the horizon.
    var sunAzimuthDegrees: Float
    /// Current field of view in degrees; the Milky Way fades as you zoom in.
    var fieldOfViewDegrees: Float
    var milkyWayStrength: Float
    /// Unit vector toward the Sun in the horizontal frame (X = East,
    /// Y = Zenith, Z = South) — the same frame `cameraToHorizontal` maps into,
    /// so the shader can take `dot(skyDirection, sunDirection)` directly and
    /// get the true scattering angle. Sent as three scalars rather than a
    /// `SIMD3<Float>` so Swift and MSL agree on the packing without any
    /// 16-byte alignment surprises.
    var sunDirectionX: Float
    var sunDirectionY: Float
    var sunDirectionZ: Float
    var _padding0: Float = 0
    var _padding1: Float = 0
    var _padding2: Float = 0

    static func make(frameData: SkyFrameData) -> SkyBackgroundUniforms {
        let centerDir = CoordinateTransformService.unitDirection(fromHorizontal: frameData.cameraCenter)
        let (right, up) = CoordinateTransformService.cameraBasis(centerDirection: centerDir)

        // Columns are the camera axes expressed in the horizontal frame, so
        // `M * localDirection` lands in the horizontal frame.
        let cameraToHorizontal = simd_double3x3(columns: (right, up, centerDir))

        let horizontalToEquatorial = Self.horizontalToEquatorial(
            observer: frameData.observerLocation,
            julianDay: frameData.julianDay
        )
        let cameraToGalactic = GalacticCoordinates.equatorialToGalactic
            * horizontalToEquatorial
            * cameraToHorizontal

        let aspectScaleY: Double
        if frameData.viewportSize.height > 0 {
            aspectScaleY = Double(frameData.viewportSize.width / frameData.viewportSize.height)
        } else {
            aspectScaleY = 1
        }

        let sunHorizontal = frameData.sunHorizontal ?? HorizontalCoordinate(altitudeDegrees: -90, azimuthDegrees: 0)
        let sunDirection = CoordinateTransformService.unitDirection(fromHorizontal: sunHorizontal)

        return SkyBackgroundUniforms(
            cameraToHorizontal: Self.floatMatrix(cameraToHorizontal),
            cameraToGalactic: Self.floatMatrix(cameraToGalactic),
            aspectScaleY: Float(aspectScaleY),
            edgeScale: Float(CoordinateTransformService.projectionEdgeScale(
                fieldOfViewDegrees: frameData.cameraFieldOfViewDegrees
            )),
            sunAltitudeDegrees: Float(sunHorizontal.altitudeDegrees),
            sunAzimuthDegrees: Float(sunHorizontal.azimuthDegrees),
            fieldOfViewDegrees: Float(frameData.cameraFieldOfViewDegrees),
            milkyWayStrength: Float(frameData.milkyWayStrength),
            sunDirectionX: Float(sunDirection.x),
            sunDirectionY: Float(sunDirection.y),
            sunDirectionZ: Float(sunDirection.z)
        )
    }

    private static func floatMatrix(_ m: simd_double3x3) -> simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(m.columns.0),
            SIMD3<Float>(m.columns.1),
            SIMD3<Float>(m.columns.2)
        )
    }

    /// Rotation from the horizontal frame (X = East, Y = Zenith, Z = South) to
    /// the equatorial Cartesian frame (X toward RA 0, Z toward the NCP).
    ///
    /// Built by writing the hour-angle frame's axes in horizontal coordinates
    /// and then rotating by the local sidereal time (RA = LST - HA).
    static func horizontalToEquatorial(
        observer: GeographicLocation,
        julianDay: Double
    ) -> simd_double3x3 {
        let phi = Angle.degreesToRadians(observer.latitudeDegrees)
        let sinPhi = sin(phi)
        let cosPhi = cos(phi)

        // Hour-angle frame axes, expressed in the (North, East, Up) triad and
        // then re-expressed in our (East, Up, South) horizontal frame.
        //   X_h (HA = 0, dec = 0)  -> south meridian point, alt = 90 - phi
        //   Y_h (HA = +90, dec = 0) -> west point on the horizon
        //   Z_h                     -> north celestial pole, alt = phi, az = 0
        func fromNEU(_ n: Double, _ e: Double, _ u: Double) -> SIMD3<Double> {
            // North = -Z, East = +X, Up = +Y in the (East, Zenith, South) frame.
            SIMD3(e, u, -n)
        }
        let xh = fromNEU(-sinPhi, 0, cosPhi)
        let yh = fromNEU(0, -1, 0)
        let zh = fromNEU(cosPhi, 0, sinPhi)

        // Columns = HA-frame axes in horizontal coordinates; its transpose maps
        // horizontal -> hour-angle frame.
        let haToHorizontal = simd_double3x3(columns: (xh, yh, zh))
        let horizontalToHA = haToHorizontal.transpose

        let lst = Angle.degreesToRadians(
            CoordinateTransformService.localSiderealTimeDegrees(
                julianDay: julianDay,
                longitudeDegrees: observer.longitudeDegrees
            )
        )
        let cosL = cos(lst)
        let sinL = sin(lst)
        // (x_eq, y_eq, z_eq) from (x_h, y_h, z_h) with RA = LST - HA.
        let haToEquatorial = simd_double3x3(rows: [
            SIMD3(cosL, sinL, 0),
            SIMD3(sinL, -cosL, 0),
            SIMD3(0, 0, 1)
        ])

        return haToEquatorial * horizontalToHA
    }
}
