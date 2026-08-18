//
//  DeepSkyObject.swift
//  Astronomy
//
//  Decodes entries from the bundled deep-sky catalogue (see
//  Data/Catalogs/deepsky.json and DATA_SOURCES.md for provenance: OpenNGC,
//  CC BY-SA 4.0, Mattia Verga).
//

import Foundation

/// The morphological classes the bundled catalogue distinguishes. Each drives
/// a different procedural treatment in the point-sprite shader.
enum DeepSkyType: String, Codable, Hashable {
    case galaxy
    case nebula
    case planetaryNebula
    case supernovaRemnant
    case darkNebula
    case openCluster
    case globularCluster

    /// Human-readable name for the info panel.
    var displayName: String {
        switch self {
        case .galaxy: return "Galaxy"
        case .nebula: return "Nebula"
        case .planetaryNebula: return "Planetary Nebula"
        case .supernovaRemnant: return "Supernova Remnant"
        case .darkNebula: return "Dark Nebula"
        case .openCluster: return "Open Cluster"
        case .globularCluster: return "Globular Cluster"
        }
    }

    /// Dark nebulae are absorption features — they are *darker* than their
    /// surroundings. Drawing them as bright blobs would be actively wrong, so
    /// they are filtered out of the render (and of search) entirely.
    var isRenderable: Bool { self != .darkNebula }
}

struct DeepSkyObject: Identifiable, Codable, Hashable {
    /// Primary catalogue identifier, e.g. "NGC0224".
    let id: String
    /// Preferred designation for display, e.g. "M31".
    let catalogName: String
    /// Common name where one exists, e.g. "Andromeda Galaxy".
    let name: String?
    let type: DeepSkyType
    /// Right Ascension in degrees (J2000).
    let ra: Double
    /// Declination in degrees (J2000).
    let dec: Double
    /// Integrated visual magnitude.
    let magnitude: Double
    /// Angular extent of the major/minor axes, in arcminutes. Nil when the
    /// source catalogue records no size, in which case the object is drawn as
    /// a small circle at the minimum visualisation size.
    let majorAxisArcmin: Double?
    let minorAxisArcmin: Double?
    /// Orientation of the major axis, in degrees **east of north** (the usual
    /// astronomical position-angle convention). Nil when unrecorded.
    let positionAngleDegrees: Double?

    /// Common name if the catalogue has one, otherwise the designation.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        return catalogName
    }

    var equatorial: EquatorialCoordinate {
        EquatorialCoordinate(rightAscensionDegrees: ra, declinationDegrees: dec)
    }

    var asCelestialObject: CelestialObject {
        var object = CelestialObject(
            id: "dso-\(id)",
            name: displayName,
            kind: .deepSky,
            equatorial: equatorial,
            magnitude: magnitude
        )
        object.deepSkyType = type
        object.catalogDesignation = catalogName
        object.majorAxisArcmin = majorAxisArcmin
        object.minorAxisArcmin = minorAxisArcmin
        object.positionAngleDegrees = positionAngleDegrees
        return object
    }
}
