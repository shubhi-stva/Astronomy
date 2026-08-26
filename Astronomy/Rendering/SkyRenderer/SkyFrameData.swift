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
    var constellations: [Constellation] = []
    /// Deep-sky objects (OpenNGC-derived). Only ~900 entries, so the geometry
    /// builder scans them linearly every frame — no spatial index needed.
    var deepSkyObjects: [DeepSkyObject] = []
    var starsByID: [Int: Star]

    /// Most recent satellite propagation tick. The geometry builder
    /// extrapolates from it every frame rather than re-propagating; see
    /// `SatelliteTracker` for why.
    var satelliteSnapshot: SatelliteSnapshot = .empty
    /// Identity records, parallel to the tracker's satellite array and indexed
    /// by `SatelliteSample.index`.
    var satelliteDescriptors: [SatelliteDescriptor] = []
    /// Master on/off for the whole satellite layer.
    var satellitesEnabled: Bool = true
    /// When false (the default), only satellites that are genuinely visible —
    /// sunlit and above the horizon — plus the notable few are drawn. When
    /// true, the entire catalogue is eligible, gated by zoom.
    var showAllSatellites: Bool = false

    /// Spatial index over `stars`. When present the geometry builder culls by
    /// sky cell before projecting anything; when nil (catalogue still loading,
    /// or a test constructing a snapshot by hand) it falls back to a full scan
    /// of `stars`, which produces identical output at lower speed.
    var starIndex: StarIndex?

    var observerLocation: GeographicLocation
    var julianDay: Double

    /// *Real* time as a Julian Day, as distinct from `julianDay`, which is the
    /// instant being displayed and may have been scrubbed anywhere by the time
    /// machine.
    ///
    /// The satellite layer is the one thing that needs to tell the two apart:
    /// aging elements at real time are drawn and labelled, while a scrub far
    /// from now is refused outright. See `SatelliteAccuracy.isDrawable`.
    /// Defaults to the wall clock, so a hand-built frame behaves as if the user
    /// were scrubbing to whatever `julianDay` it sets — which is exactly what
    /// such a frame is modelling.
    var nowJulianDay: Double = JulianDate.julianDay(from: Date())

    var cameraCenter: HorizontalCoordinate
    var cameraFieldOfViewDegrees: Double

    var viewportSize: CGSize

    /// Sun position in horizontal coordinates, precomputed once per frame and
    /// reused for twilight tinting and the Moon's bright-limb orientation.
    var sunHorizontal: HorizontalCoordinate?
    /// Sun/Moon equatorial positions, kept for phase computation.
    var sunEquatorial: EquatorialCoordinate?
    var moonEquatorial: EquatorialCoordinate?

    /// Overall Milky Way opacity multiplier (0 disables the layer).
    var milkyWayStrength: Double = 1.0

    /// Identifier of the currently selected object, so the renderer can draw a
    /// selection ring and boost that object's label priority.
    var selectedObjectID: String?

    /// Sun altitude in degrees, or a deep-night sentinel if the ephemeris has
    /// not been computed. Drives the sky-brightness / star-visibility model.
    var sunAltitudeDegrees: Double {
        sunHorizontal?.altitudeDegrees ?? -90
    }

    /// Illuminated fraction of the Moon's disk (Meeus ch. 48), 0...1.
    /// Defaults to a full disk if the ephemeris hasn't been computed yet.
    var moonIlluminatedFraction: Double {
        guard let sunEquatorial, let moonEquatorial else { return 1.0 }
        return MoonPhase.illuminatedFraction(sun: sunEquatorial, moon: moonEquatorial)
    }

    static let empty = SkyFrameData(
        stars: [],
        solarSystemObjects: [],
        constellationLines: [],
        starsByID: [:],
        observerLocation: .fallbackObserver,
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
