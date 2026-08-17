//
//  Constellation.swift
//  Astronomy
//
//  Constellation name + approximate sky centre, used only for placing the
//  constellation name labels. See DATA_SOURCES.md for provenance and accuracy
//  caveats (these are approximate figure centroids, not IAU boundary
//  centroids — good to a few degrees, which is invisible at label scale).
//

import Foundation

struct Constellation: Codable, Hashable, Identifiable {
    let name: String
    /// Right Ascension of the approximate centre, in degrees (J2000).
    let ra: Double
    /// Declination of the approximate centre, in degrees (J2000).
    let dec: Double

    var id: String { name }

    var equatorial: EquatorialCoordinate {
        EquatorialCoordinate(rightAscensionDegrees: ra, declinationDegrees: dec)
    }
}
