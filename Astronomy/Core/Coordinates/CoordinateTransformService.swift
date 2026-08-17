//
//  CoordinateTransformService.swift
//  Astronomy
//
//  Converts equatorial (RA/Dec) coordinates to horizontal (Alt/Az)
//  coordinates for a given observer location and time, and projects
//  horizontal coordinates onto a 2D screen-space unit disc for the camera.
//
//  Reference: Jean Meeus, "Astronomical Algorithms", 2nd ed., Chapter 12
//  (Sidereal Time) and Chapter 13 (Transformation of Coordinates).
//

import CoreGraphics
import Foundation
import simd

enum CoordinateTransformService {

    /// Greenwich Mean Sidereal Time, in degrees, for a given Julian Day.
    /// Meeus 12.4 (low-precision form referenced to J2000.0).
    static func greenwichMeanSiderealTimeDegrees(julianDay jd: Double) -> Double {
        let t = JulianDate.julianCenturies(fromJulianDay: jd)
        var gmst = 280.46061837
            + 360.98564736629 * (jd - JulianDate.j2000)
            + 0.000387933 * t * t
            - (t * t * t) / 38_710_000.0
        gmst = Angle.normalizeDegrees(gmst)
        return gmst
    }

    /// Local Apparent/Mean Sidereal Time in degrees for an observer longitude
    /// (east-positive) at the given Julian Day. Ignores the small
    /// nutation-in-longitude correction (mean, not apparent) — sufficient at
    /// arcminute precision for MVP.
    static func localSiderealTimeDegrees(julianDay jd: Double, longitudeDegrees: Double) -> Double {
        Angle.normalizeDegrees(greenwichMeanSiderealTimeDegrees(julianDay: jd) + longitudeDegrees)
    }

    /// Converts equatorial coordinates to horizontal (Alt/Az) coordinates.
    ///
    /// Standard spherical-trigonometry formulas (Meeus Ch. 13):
    ///   H = LST - RA                     (hour angle)
    ///   sin(alt) = sin(dec)sin(lat) + cos(dec)cos(lat)cos(H)
    ///   tan(Az)  = sin(H) / (cos(H)sin(lat) - tan(dec)cos(lat))
    ///
    /// Azimuth here is measured from north, increasing eastward (compass
    /// convention), which is the convention most consumers expect.
    static func horizontal(
        from equatorial: EquatorialCoordinate,
        observer: GeographicLocation,
        julianDay jd: Double
    ) -> HorizontalCoordinate {
        let lst = localSiderealTimeDegrees(julianDay: jd, longitudeDegrees: observer.longitudeDegrees)
        let hourAngleDeg = Angle.normalizeDegrees(lst - equatorial.rightAscensionDegrees)

        let h = Angle.degreesToRadians(hourAngleDeg)
        let dec = Angle.degreesToRadians(equatorial.declinationDegrees)
        let lat = Angle.degreesToRadians(observer.latitudeDegrees)

        let sinAlt = sin(dec) * sin(lat) + cos(dec) * cos(lat) * cos(h)
        let altitude = asin(max(-1.0, min(1.0, sinAlt)))

        // Azimuth measured from North, eastward. Using Meeus's south-referenced
        // formula (measured from South, westward) then converting to the
        // North-referenced compass convention (Az_north = Az_meeus + 180).
        let y = sin(h)
        let x = cos(h) * sin(lat) - tan(dec) * cos(lat)
        let azimuthFromSouth = atan2(y, x)
        let azimuthFromNorth = Angle.normalizeDegrees(Angle.radiansToDegrees(azimuthFromSouth) + 180.0)

        return HorizontalCoordinate(
            altitudeDegrees: Angle.radiansToDegrees(altitude),
            azimuthDegrees: azimuthFromNorth
        )
    }

    /// Projects a horizontal coordinate onto a unit hemisphere direction
    /// vector, with +Y = zenith, useful as an input to camera projection.
    static func unitDirection(fromHorizontal horizontal: HorizontalCoordinate) -> SIMD3<Double> {
        let alt = Angle.degreesToRadians(horizontal.altitudeDegrees)
        let az = Angle.degreesToRadians(horizontal.azimuthDegrees)

        // Standard horizon-to-Cartesian mapping: X = East, Y = Zenith, Z = North(-)/South(+).
        let cosAlt = cos(alt)
        let x = cosAlt * sin(az)
        let y = sin(alt)
        let z = -cosAlt * cos(az)
        return SIMD3(x, y, z)
    }

    /// Builds the camera-local orthonormal basis (screen-right, screen-up) for
    /// a viewing direction, using the zenith as the world up reference.
    ///
    /// The observer stands *inside* the celestial sphere looking outward, so
    /// the correct right-handed camera basis is `right = forward x up`. (The
    /// opposite order, `up x forward`, yields a mirrored sky — facing south it
    /// would put east on the right instead of west.)
    ///
    /// Consequences used by the input layer: screen +X points in the direction
    /// of *increasing* azimuth and screen +Y in the direction of *increasing*
    /// altitude.
    static func cameraBasis(centerDirection: SIMD3<Double>) -> (right: SIMD3<Double>, up: SIMD3<Double>) {
        let worldUp = SIMD3<Double>(0, 1, 0)
        var right = simd_cross(centerDirection, worldUp)
        if simd_length(right) < 1e-8 {
            // Looking straight up/down: any horizontal right vector will do.
            right = SIMD3<Double>(1, 0, 0)
        }
        right = simd_normalize(right)
        let up = simd_normalize(simd_cross(right, centerDirection))
        return (right, up)
    }

    /// Applies the viewport aspect-ratio correction to a square projection
    /// result, so that `fieldOfViewDegrees` is the full **horizontal** field of
    /// view.
    ///
    /// The X axis maps straight through to -1...1 (the horizontal FOV always
    /// spans the viewport width). The Y axis is scaled by `width / height`,
    /// which is equivalent to saying the *vertical* field of view is the
    /// horizontal one scaled by `height / width`. At aspect 1:1 nothing
    /// changes; on a landscape window the visible vertical sky shrinks
    /// proportionally instead of the horizontal sky being squeezed.
    static func aspectCorrected(_ ndc: SIMD2<Double>, viewportSize: CGSize) -> SIMD2<Double> {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return ndc }
        let scaleY = Double(viewportSize.width / viewportSize.height)
        return SIMD2(ndc.x, ndc.y * scaleY)
    }

    /// Inverse of `aspectCorrected` — turns a viewport NDC point (e.g. a click
    /// location) back into square projection space.
    static func aspectUncorrected(_ ndc: SIMD2<Double>, viewportSize: CGSize) -> SIMD2<Double> {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return ndc }
        let scaleY = Double(viewportSize.width / viewportSize.height)
        return SIMD2(ndc.x, ndc.y / scaleY)
    }

    /// The scale factor mapping tangent-plane projection units to the -1...1
    /// range for a given (horizontal) field of view. Exposed so the background
    /// shader can invert the projection per pixel.
    static func projectionEdgeScale(fieldOfViewDegrees: Double) -> Double {
        let halfFovRad = Angle.degreesToRadians(fieldOfViewDegrees / 2.0)
        return 2.0 / (1.0 + cos(halfFovRad)) * sin(halfFovRad)
    }

    /// Stereographic projection of a horizontal-sky direction to normalized
    /// screen coordinates (-1...1), centered on `centerAltAz` with the given
    /// field of view (degrees, full width). Points behind the camera return
    /// `nil`.
    static func stereographicProject(
        horizontal: HorizontalCoordinate,
        center: HorizontalCoordinate,
        fieldOfViewDegrees: Double
    ) -> SIMD2<Double>? {
        let dir = unitDirection(fromHorizontal: horizontal)
        let centerDir = unitDirection(fromHorizontal: center)

        let (right, up) = cameraBasis(centerDirection: centerDir)

        let cosC = simd_dot(centerDir, dir)
        if cosC < -0.9999 {
            return nil // Antipodal point — undefined.
        }

        // Standard stereographic projection formula from the tangent plane.
        let k = 2.0 / (1.0 + cosC)
        guard k.isFinite, cosC > -0.999 else { return nil }

        let localX = simd_dot(right, dir)
        let localY = simd_dot(up, dir)

        let projX = k * localX
        let projY = k * localY

        // Scale so that the configured field of view maps to the -1...1 range.
        let edgeScale = projectionEdgeScale(fieldOfViewDegrees: fieldOfViewDegrees)
        guard edgeScale > 1e-6 else { return nil }

        let normalizedX = projX / edgeScale
        let normalizedY = projY / edgeScale

        // Reject points too far outside the visible frame to avoid rendering
        // artifacts from the projection's singularities.
        if cosC < 0, (normalizedX * normalizedX + normalizedY * normalizedY) > 16 {
            return nil
        }

        return SIMD2(normalizedX, normalizedY)
    }
}
