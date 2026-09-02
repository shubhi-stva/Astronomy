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
/// Stars are carried as the catalogue row rather than as a built
/// `CelestialObject`, and converted only when something actually asks for one.
///
/// Turning a `Star` into a `CelestialObject` allocates two strings — the
/// `"star-<row>"` identity and the display name — and at a wide, dark field the
/// builder produces ~2,500 of them per frame purely so that a *click*, which
/// happens a few times a minute at most, can say what it hit. Measured on the
/// real catalogue that was 0.69 ms of a 2.15 ms frame in Release: the single
/// largest item left in the pipeline, and all of it thrown away unread.
///
/// The three things anyone asks of a `ProjectedObject` are its screen position
/// (free), whether it is the selected one (`matches(id:)`, free), and — for the
/// one element that answers yes — the whole object. Only the last converts.
struct ProjectedObject {

    private enum Source {
        case resolved(CelestialObject)
        case star(Star)
    }

    private let source: Source
    let ndcPosition: SIMD2<Double>

    init(object: CelestialObject, ndcPosition: SIMD2<Double>) {
        self.source = .resolved(object)
        self.ndcPosition = ndcPosition
    }

    init(star: Star, ndcPosition: SIMD2<Double>) {
        self.source = .star(star)
        self.ndcPosition = ndcPosition
    }

    /// The object this point represents. For a star this builds the
    /// `CelestialObject` on demand — identical to what the builder used to
    /// store eagerly, so callers see no difference beyond when the work happens.
    var object: CelestialObject {
        switch source {
        case .resolved(let object): return object
        case .star(let star): return star.asCelestialObject
        }
    }

    /// Whether this is the object with `id`, without building a
    /// `CelestialObject` to find out. `starRowID` is the row id already parsed
    /// out of the query by `Star.rowID(fromObjectID:)`, so the scan over a few
    /// thousand points costs one integer compare each.
    func matches(objectID id: String, starRowID: Int?) -> Bool {
        switch source {
        case .resolved(let object): return object.id == id
        case .star(let star): return star.id == starRowID
        }
    }
}
