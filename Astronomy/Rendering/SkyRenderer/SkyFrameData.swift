//
//  SkyFrameData.swift
//  Astronomy
//
//  Immutable snapshot of everything the renderer needs to draw one frame.
//  Built by the Sky feature's view model and handed to `SkyRenderer` each
//  frame — keeps the rendering layer decoupled from SwiftUI/Observation.
//

import CoreGraphics
import Foundation
import simd

struct SkyFrameData {
    var stars: [Star]
    var solarSystemObjects: [CelestialObject]
    var constellationLines: [ConstellationLineSegment]
    var starsByID: [Int: Star]

    var observerLocation: GeographicLocation
    var julianDay: Double

    var cameraCenter: HorizontalCoordinate
    var cameraFieldOfViewDegrees: Double

    var viewportSize: CGSize

    static let empty = SkyFrameData(
        stars: [],
        solarSystemObjects: [],
        constellationLines: [],
        starsByID: [:],
        observerLocation: .newYork,
        julianDay: JulianDate.j2000,
        cameraCenter: HorizontalCoordinate(altitudeDegrees: 45, azimuthDegrees: 180),
        cameraFieldOfViewDegrees: 90,
        viewportSize: .zero
    )
}

/// A projected screen-space point plus the source object, produced by the
/// renderer/hit-tester so selection logic can reuse the exact same
/// projection math as drawing.
struct ProjectedObject {
    let object: CelestialObject
    let ndcPosition: SIMD2<Double>
}
