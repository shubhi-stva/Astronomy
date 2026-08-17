//
//  Star.swift
//  Astronomy
//
//  Decodes entries from the bundled star catalog JSON (see
//  Data/Catalogs/stars.json and DATA_SOURCES.md for provenance).
//

import Foundation

struct Star: Identifiable, Codable, Hashable {
    let id: Int
    let name: String?
    /// Right Ascension in degrees (J2000).
    let ra: Double
    /// Declination in degrees (J2000).
    let dec: Double
    let magnitude: Double
    /// B-V color index; used to derive a realistic star color for rendering.
    let colorIndex: Double?
    let spectralType: String?

    var displayName: String {
        name ?? "HR \(id)"
    }

    var asCelestialObject: CelestialObject {
        CelestialObject(
            id: "star-\(id)",
            name: displayName,
            kind: .star,
            equatorial: EquatorialCoordinate(rightAscensionDegrees: ra, declinationDegrees: dec),
            magnitude: magnitude,
            colorIndex: colorIndex
        )
    }
}

struct ConstellationLineSegment: Codable, Hashable {
    /// Star catalog IDs of the two endpoints.
    let starID1: Int
    let starID2: Int
}
