//
//  Camera.swift
//  Astronomy
//
//  The sky-view camera: where it's looking (Alt/Az center) and how wide a
//  field of view it shows. Drag gestures rotate the center; scroll changes
//  the field of view (zoom). Pure state — no Metal or SwiftUI imports, so
//  it can be driven identically by mouse/trackpad gestures in SwiftUI and
//  consumed by the Metal renderer.
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

    /// Field of view (full width), in degrees. Smaller = more zoomed in.
    private(set) var fieldOfViewDegrees: Double

    static let minFieldOfView = 3.0
    static let maxFieldOfView = 150.0

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

    /// Applies a drag delta (in points) to pan/rotate the camera. The
    /// rotation speed scales with the current field of view so a drag feels
    /// consistent whether zoomed in or out.
    func applyDrag(deltaX: Double, deltaY: Double, viewportSize: CGSize) {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        let degreesPerPointX = fieldOfViewDegrees / Double(viewportSize.width)
        let degreesPerPointY = fieldOfViewDegrees / Double(viewportSize.width) // keep aspect-consistent feel

        centerAzimuthDegrees = Angle.normalizeDegrees(centerAzimuthDegrees - deltaX * degreesPerPointX)
        centerAltitudeDegrees = min(89.5, max(-89.5, centerAltitudeDegrees + deltaY * degreesPerPointY))
    }

    /// Applies a scroll/pinch delta to zoom (change field of view).
    func applyZoom(delta: Double) {
        let factor = 1.0 + (delta * 0.01)
        fieldOfViewDegrees = min(Self.maxFieldOfView, max(Self.minFieldOfView, fieldOfViewDegrees * factor))
    }

    /// Recenters the camera directly on a horizontal coordinate (used by search).
    func center(on horizontal: HorizontalCoordinate) {
        centerAltitudeDegrees = min(89.5, max(-89.5, horizontal.altitudeDegrees))
        centerAzimuthDegrees = Angle.normalizeDegrees(horizontal.azimuthDegrees)
    }
}
