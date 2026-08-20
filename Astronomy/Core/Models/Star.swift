//
//  Star.swift
//  Astronomy
//
//  Decodes entries from the bundled star catalog JSON (see
//  Data/Catalogs/stars.json and DATA_SOURCES.md for provenance).
//

import Foundation

struct Star: Identifiable, Codable, Hashable {
    /// HYG catalogue **row id**. An internal join key (constellation line
    /// segments reference it) and nothing else — in particular it is *not* an
    /// HR number, which is why `displayName` no longer pretends it is.
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

    // MARK: - Designations
    //
    // Only 431 of the 83,479 catalogue entries have a proper name. These are
    // how the other 83,048 are referred to, and without them they were
    // unsearchable: the app carried no identifier for them at all. All are
    // optional and absent from the JSON when the HYG row has no value, which
    // is why the keys are short and omitted rather than emitted as empty
    // strings — see DATA_SOURCES.md for the size cost.

    /// Hipparcos number.
    let hip: Int?
    /// Henry Draper number.
    let hd: Int?
    /// Harvard Revised / Bright Star Catalogue number.
    let hr: Int?
    /// Gliese catalogue designation, as printed ("Gl 244A").
    let gliese: String?
    /// HYG's compact Bayer/Flamsteed designation ("9Alp CMa"): an optional
    /// Flamsteed number, an optional three-letter Bayer code, and the
    /// constellation abbreviation. `StarDesignations` unpacks it.
    let bayerFlamsteed: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, ra, dec, magnitude, colorIndex, spectralType
        case hip, hd, hr
        case gliese = "gl"
        case bayerFlamsteed = "bf"
    }

    /// Explicit memberwise init so the designations can default to absent.
    /// Most construction sites (tests, synthetic fixtures) care about position
    /// and brightness only, and should not have to spell out five nils.
    init(
        id: Int, name: String?, ra: Double, dec: Double, magnitude: Double,
        colorIndex: Double?, spectralType: String?,
        hip: Int? = nil, hd: Int? = nil, hr: Int? = nil,
        gliese: String? = nil, bayerFlamsteed: String? = nil
    ) {
        self.id = id
        self.name = name
        self.ra = ra
        self.dec = dec
        self.magnitude = magnitude
        self.colorIndex = colorIndex
        self.spectralType = spectralType
        self.hip = hip
        self.hd = hd
        self.hr = hr
        self.gliese = gliese
        self.bayerFlamsteed = bayerFlamsteed
    }

    /// The best name to put on screen, in descending order of how much it
    /// tells a human: proper name, then the Bayer/Flamsteed designation, then
    /// the catalogue numbers, brightest-catalogue first. The last resort is
    /// labelled as what it is — an internal row id — rather than dressed up as
    /// an HR number, which is what the old `"HR \(id)"` fallback did and which
    /// was simply wrong (Sirius is row 32263 and HR 2491).
    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let designation = StarDesignations.displayDesignation(bayerFlamsteed: bayerFlamsteed) {
            return designation
        }
        if let hr { return "HR \(hr)" }
        if let hd { return "HD \(hd)" }
        if let hip { return "HIP \(hip)" }
        if let gliese, !gliese.isEmpty { return gliese }
        return "HYG \(id)"
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
