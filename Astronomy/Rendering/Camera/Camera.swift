//
//  Camera.swift
//  Astronomy
//
//  The sky-view camera: where it's looking (Alt/Az center) and how wide a
//  field of view it shows. Trackpad two-finger swipe / mouse drag rotate the
//  center; pinch-magnify and scroll change the field of view (zoom). Pure
//  state — no Metal or SwiftUI imports, so it can be driven identically by
//  mouse/trackpad gestures in SwiftUI and consumed by the Metal renderer.
//
//  Continuous behaviour (pan momentum, eased "focus on object" flights) is
//  advanced by `tick()`, which the sky view model calls once per rendered
//  frame. Keeping the integration here — rather than in a SwiftUI animation —
//  means the camera stays the single source of truth for where we're looking.
//

import Foundation
import Observation

@Observable
@MainActor
final class Camera {

    /// Center of view, altitude in degrees (-90...90, clamped near poles).
    private(set) var centerAltitudeDegrees: Double
    /// Center of view, azimuth in degrees (0...360, wraps).
    private(set) var centerAzimuthDegrees: Double

    /// Field of view (full *horizontal* width), in degrees. Smaller = more
    /// zoomed in. The vertical field of view is derived from the viewport
    /// aspect ratio at projection time.
    private(set) var fieldOfViewDegrees: Double

    /// The tightest field the camera will zoom to.
    ///
    /// This was 3 degrees, and at 3 degrees **no planet could ever resolve**.
    /// Mars at its closest opposition subtends 25 arcseconds; across a
    /// 1600-point viewport at a 3-degree field that is three and a half points
    /// — a marker, not a disk. Jupiter reached seven. So the surface maps, the
    /// procedural bands and Saturn's rings were all sitting behind a zoom limit
    /// that could not be reached, and `StarAppearance.detailLevel` (which needs
    /// 16 points to begin and 52 to finish) never left zero for anything but
    /// the Moon.
    ///
    /// 0.15 degrees — nine arcminutes — puts Mars at opposition at about 70
    /// points and Jupiter at nearly 150, which is where a disk genuinely reads
    /// as a disk. It is also a normal limit for a desktop planetarium; the
    /// binding constraint on this app is not the projection but the resolution
    /// of what it has to draw.
    ///
    /// Nothing else needs adjusting to suit it. `limitingMagnitude` and the
    /// shader's zoom darkening both clamp at their narrow ends, so they simply
    /// hold their tightest values below 3 degrees, which is what they should do
    /// — the star catalogue bottoms out at magnitude 9 and no amount of further
    /// zoom adds a star.
    static let minFieldOfView = 0.15
    static let maxFieldOfView = 150.0

    // MARK: - Momentum state

    /// Residual pan velocity in degrees/second (screen-space X and Y), decayed
    /// each tick. Screen +X is the direction of increasing azimuth, screen +Y
    /// is downward (matching the drag delta convention).
    private var panVelocity: (x: Double, y: Double) = (0, 0)

    /// Exponential decay constant. A velocity decays to ~2% of its initial
    /// value in `-ln(0.02)/decay` seconds ≈ 0.55 s at 7.0 — a short, damped
    /// glide rather than a free-floating scroll.
    private static let momentumDecayPerSecond = 7.0
    /// Below this speed the glide is snapped to a stop so it doesn't creep.
    private static let momentumStopThreshold = 1.5

    private var lastTickTime: CFTimeInterval?

    // MARK: - Focus flight state

    private struct FocusFlight {
        var startAltitude: Double
        var startAzimuthDelta: Double   // shortest signed path, degrees
        var startAzimuth: Double
        var targetAltitude: Double
        var startFieldOfView: Double
        var targetFieldOfView: Double
        var elapsed: Double
        var duration: Double
    }

    private var focusFlight: FocusFlight?

    /// True while an eased camera flight is in progress.
    var isFlying: Bool { focusFlight != nil }

    init(
        centerAltitudeDegrees: Double = 45,
        centerAzimuthDegrees: Double = 180,
        fieldOfViewDegrees: Double = 90
    ) {
        self.centerAltitudeDegrees = centerAltitudeDegrees
        self.centerAzimuthDegrees = centerAzimuthDegrees
        self.fieldOfViewDegrees = fieldOfViewDegrees
    }

    var centerHorizontal: HorizontalCoordinate {
        HorizontalCoordinate(altitudeDegrees: centerAltitudeDegrees, azimuthDegrees: centerAzimuthDegrees)
    }

    // MARK: - Panning

    /// Degrees of sky travelled per point of cursor/finger movement. Scales
    /// with the field of view so a swipe feels identical zoomed in or out.
    /// Uses the viewport *width* for both axes because the projection maps the
    /// horizontal field of view to the full viewport width (see
    /// `CoordinateTransformService.aspectCorrected`).
    static func degreesPerPoint(fieldOfViewDegrees: Double, viewportSize: CGSize) -> Double {
        guard viewportSize.width > 0 else { return 0 }
        return fieldOfViewDegrees / Double(viewportSize.width)
    }

    /// Applies a drag/swipe delta (in points) to pan the camera.
    ///
    /// Convention: `deltaX` is positive when the finger moves right, `deltaY`
    /// is positive when the finger moves *down* the screen. The content
    /// follows the finger, so the camera center moves in the opposite screen
    /// direction.
    ///
    /// Screen +X corresponds to increasing azimuth and screen +Y (upward, in
    /// NDC) to increasing altitude — see the basis construction in
    /// `CoordinateTransformService.stereographicProject`. Hence a rightward
    /// swipe *decreases* azimuth and a downward swipe *increases* altitude.
    func applyDrag(deltaX: Double, deltaY: Double, viewportSize: CGSize) {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        cancelFlight()
        let degreesPerPoint = Self.degreesPerPoint(fieldOfViewDegrees: fieldOfViewDegrees, viewportSize: viewportSize)

        // Azimuth steps shrink near the poles (a degree of azimuth covers less
        // sky), keeping the apparent pan speed roughly constant overhead.
        let latitudeCompression = max(0.15, cos(Angle.degreesToRadians(centerAltitudeDegrees)))

        centerAzimuthDegrees = Angle.normalizeDegrees(
            centerAzimuthDegrees - deltaX * degreesPerPoint / latitudeCompression
        )
        centerAltitudeDegrees = min(89.5, max(-89.5, centerAltitudeDegrees + deltaY * degreesPerPoint))
    }

    /// Starts a momentum glide from a release velocity in points/second.
    func beginMomentum(velocityX: Double, velocityY: Double, viewportSize: CGSize) {
        guard viewportSize.width > 0 else { return }
        let degreesPerPoint = Self.degreesPerPoint(fieldOfViewDegrees: fieldOfViewDegrees, viewportSize: viewportSize)
        let vx = velocityX * degreesPerPoint
        let vy = velocityY * degreesPerPoint
        guard hypot(vx, vy) > Self.momentumStopThreshold else { return }
        panVelocity = (vx, vy)
    }

    func stopMomentum() {
        panVelocity = (0, 0)
    }

    // MARK: - Zooming

    /// Applies a scroll-wheel style zoom delta (arbitrary units).
    func applyZoom(delta: Double) {
        applyZoomFactor(1.0 + delta * 0.01)
    }

    /// Applies a multiplicative zoom factor, e.g. from a pinch-magnify
    /// recognizer where `factor = 1 + magnification`.
    func applyZoomFactor(_ factor: Double) {
        guard factor > 0, factor.isFinite else { return }
        cancelFlight()
        fieldOfViewDegrees = Self.clampFieldOfView(fieldOfViewDegrees * factor)
    }

    static func clampFieldOfView(_ value: Double) -> Double {
        min(maxFieldOfView, max(minFieldOfView, value))
    }

    // MARK: - Recentering

    /// Recenters the camera directly on a horizontal coordinate (used by search).
    func center(on horizontal: HorizontalCoordinate) {
        cancelFlight()
        stopMomentum()
        centerAltitudeDegrees = min(89.5, max(-89.5, horizontal.altitudeDegrees))
        centerAzimuthDegrees = Angle.normalizeDegrees(horizontal.azimuthDegrees)
    }

    /// Starts a smooth, eased flight that centers `horizontal` and optionally
    /// settles at `fieldOfViewDegrees`.
    func flyTo(
        _ horizontal: HorizontalCoordinate,
        fieldOfViewDegrees targetFOV: Double? = nil,
        duration: Double = 0.75
    ) {
        stopMomentum()
        let targetAlt = min(89.5, max(-89.5, horizontal.altitudeDegrees))
        let targetAz = Angle.normalizeDegrees(horizontal.azimuthDegrees)
        focusFlight = FocusFlight(
            startAltitude: centerAltitudeDegrees,
            startAzimuthDelta: Self.shortestAngularDelta(from: centerAzimuthDegrees, to: targetAz),
            startAzimuth: centerAzimuthDegrees,
            targetAltitude: targetAlt,
            startFieldOfView: fieldOfViewDegrees,
            targetFieldOfView: Self.clampFieldOfView(targetFOV ?? fieldOfViewDegrees),
            elapsed: 0,
            duration: max(0.05, duration)
        )
    }

    private func cancelFlight() {
        focusFlight = nil
    }

    /// Shortest signed rotation, in degrees, from `a` to `b` (result in -180...180).
    static func shortestAngularDelta(from a: Double, to b: Double) -> Double {
        var delta = (b - a).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    // MARK: - Per-frame integration

    /// Advances momentum and any in-flight focus animation. Called once per
    /// rendered frame; uses wall-clock deltas so behaviour is frame-rate
    /// independent.
    func tick(now: CFTimeInterval = CACurrentMediaTimeShim()) {
        defer { lastTickTime = now }
        guard let last = lastTickTime else { return }
        // Clamp so a stalled/backgrounded frame doesn't teleport the camera.
        let dt = min(0.1, max(0.0, now - last))
        guard dt > 0 else { return }

        advanceFlight(dt: dt)
        advanceMomentum(dt: dt)
    }

    private func advanceMomentum(dt: Double) {
        guard panVelocity.x != 0 || panVelocity.y != 0 else { return }
        guard focusFlight == nil else { panVelocity = (0, 0); return }

        let latitudeCompression = max(0.15, cos(Angle.degreesToRadians(centerAltitudeDegrees)))
        centerAzimuthDegrees = Angle.normalizeDegrees(
            centerAzimuthDegrees - panVelocity.x * dt / latitudeCompression
        )
        centerAltitudeDegrees = min(89.5, max(-89.5, centerAltitudeDegrees + panVelocity.y * dt))

        let decay = exp(-Self.momentumDecayPerSecond * dt)
        panVelocity = (panVelocity.x * decay, panVelocity.y * decay)
        if hypot(panVelocity.x, panVelocity.y) < Self.momentumStopThreshold {
            panVelocity = (0, 0)
        }
    }

    private func advanceFlight(dt: Double) {
        guard var flight = focusFlight else { return }
        flight.elapsed += dt
        let t = min(1.0, flight.elapsed / flight.duration)
        let eased = Self.easeInOut(t)

        centerAltitudeDegrees = flight.startAltitude + (flight.targetAltitude - flight.startAltitude) * eased
        centerAzimuthDegrees = Angle.normalizeDegrees(flight.startAzimuth + flight.startAzimuthDelta * eased)
        fieldOfViewDegrees = Self.clampFieldOfView(
            flight.startFieldOfView + (flight.targetFieldOfView - flight.startFieldOfView) * eased
        )

        if t >= 1.0 {
            focusFlight = nil
        } else {
            focusFlight = flight
        }
    }

    /// Smootherstep easing — zero velocity at both ends, no overshoot.
    static func easeInOut(_ t: Double) -> Double {
        let x = min(1.0, max(0.0, t))
        return x * x * x * (x * (x * 6 - 15) + 10)
    }
}

/// Small indirection so `Camera` stays free of QuartzCore in tests while still
/// using the same monotonic clock the display link does at runtime.
@inline(__always)
func CACurrentMediaTimeShim() -> CFTimeInterval {
    ProcessInfo.processInfo.systemUptime
}
