//
//  Satellite.swift
//  Astronomy
//
//  Model types for artificial satellites: the catalogue entry, the orbital
//  regime it falls into, and the per-tick propagated sample the renderer
//  consumes.
//

import Foundation
import simd

/// Coarse orbital regime, classified from the element set's mean motion and
/// eccentricity the way the operational community does it.
///
/// The boundaries are conventional rather than physical, and the classification
/// exists mostly so the UI can say something useful and so the renderer can
/// tint by regime.
enum OrbitalRegime: String, Codable, Hashable, Sendable {
    /// Low Earth orbit: period under about 128 minutes.
    case lowEarth
    /// Medium Earth orbit: everything between LEO and the geosynchronous belt.
    /// GPS, Galileo, GLONASS and friends live here.
    case mediumEarth
    /// Geosynchronous: a period within a few percent of one sidereal day and a
    /// near-circular orbit.
    case geosynchronous
    /// Highly elliptical: eccentricity above 0.25. Molniya and Tundra orbits,
    /// plus a long tail of transfer and disposal orbits.
    case highlyElliptical

    var displayName: String {
        switch self {
        case .lowEarth: return "Low Earth orbit"
        case .mediumEarth: return "Medium Earth orbit"
        case .geosynchronous: return "Geosynchronous orbit"
        case .highlyElliptical: return "Highly elliptical orbit"
        }
    }

    var shortName: String {
        switch self {
        case .lowEarth: return "LEO"
        case .mediumEarth: return "MEO"
        case .geosynchronous: return "GEO"
        case .highlyElliptical: return "HEO"
        }
    }

    /// Classifies from the raw TLE quantities.
    ///
    /// Eccentricity is tested first: a Molniya satellite has a 12-hour period
    /// that would otherwise read as MEO, but its orbit is nothing like a
    /// navigation satellite's and calling it MEO would be misleading.
    static func classify(meanMotionRevsPerDay n: Double, eccentricity e: Double) -> OrbitalRegime {
        if e >= 0.25 { return .highlyElliptical }
        // One sidereal day is 1.00273790935 mean solar days, so a
        // geosynchronous satellite completes 1.0027 revolutions per solar day.
        if n >= 0.85 && n <= 1.15 { return .geosynchronous }
        // 128 minutes is the usual LEO/MEO dividing line (about 11.25 rev/day).
        if n >= 11.25 { return .lowEarth }
        return .mediumEarth
    }
}

/// A satellite as loaded from the catalogue: identity, classification, and the
/// initialised propagator that produces its position.
///
/// The propagator is a value type carrying mutable integration state, so this
/// is a `final class` rather than a struct: the tracker mutates one satellite's
/// propagator in place on each tick, and copying an 80-field record per
/// satellite per tick would be pure waste.
final class Satellite: @unchecked Sendable {

    let catalogNumber: Int
    let name: String
    let regime: OrbitalRegime
    /// International designator, e.g. "98067A" for the ISS.
    let internationalDesignator: String
    /// Element-set epoch as a Julian Day, surfaced so the info panel can show
    /// how stale the elements are.
    let epochJulianDay: Double
    /// True when this object is one of the handful always worth drawing and
    /// labelling regardless of whether it happens to be visible.
    let isNotable: Bool

    /// Stable identifier used by selection, search and the label engine.
    var id: String { "sat-\(catalogNumber)" }

    /// The initialised SGP4/SDP4 propagator. Mutated in place by the tracker;
    /// see `SatelliteTracker` for the concurrency discipline that makes the
    /// `@unchecked Sendable` above true (each satellite is touched by exactly
    /// one task at a time).
    private var storedPropagator: SGP4Propagator

    /// Propagates this satellite to an absolute Julian Day, advancing the
    /// propagator's own integration state in place.
    ///
    /// Wrapping the mutation in a method rather than exposing the propagator is
    /// deliberate: `SGP4Propagator` is a large value type, and letting callers
    /// write `satellite.propagator.propagate(...)` from a concurrent context
    /// either copies eighty fields or trips Swift's exclusivity checking. This
    /// keeps the mutation local and the record in place.
    func propagate(julianDay: Double) -> SGP4State? {
        try? storedPropagator.propagate(julianDay: julianDay)
    }

    /// Orbital period in minutes, from the model's un-Kozai'd mean motion.
    var periodMinutes: Double { storedPropagator.periodMinutes }

    /// True when this object takes the SDP4 deep-space branch.
    var usesDeepSpaceModel: Bool { storedPropagator.isDeepSpace }

    init?(tle: TwoLineElement) {
        guard let propagator = SGP4Propagator(tle: tle) else { return nil }
        self.storedPropagator = propagator
        self.catalogNumber = tle.catalogNumber
        self.name = Self.displayName(from: tle.name, catalogNumber: tle.catalogNumber)
        self.regime = OrbitalRegime.classify(
            meanMotionRevsPerDay: tle.meanMotionRevsPerDay,
            eccentricity: tle.eccentricity
        )
        self.internationalDesignator = tle.internationalDesignator
        self.epochJulianDay = tle.epochJulianDay
        self.isNotable = Self.notableCatalogNumbers.contains(tle.catalogNumber)
    }

    /// Catalogue names arrive in fixed-width upper case ("ISS (ZARYA)     ").
    /// Trimmed here; the case is left alone because these are the objects'
    /// registered designations, not prose.
    private static func displayName(from raw: String, catalogNumber: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "NORAD \(catalogNumber)" : trimmed
    }

    /// The satellites always worth drawing, by NORAD catalog number.
    ///
    /// Deliberately short and hand-picked: crewed stations, the famous
    /// observatories, and the weather/imaging workhorses people actually go
    /// looking for. Everything else earns its place on screen by being genuinely
    /// visible right now (sunlit and above the horizon) or by the user asking
    /// for the full catalogue — see `SkyGeometryBuilder.buildSatellites`.
    ///
    /// A curated list is the honest option here. The catalogue carries no
    /// brightness or size field, so "notable" cannot be derived; pretending
    /// otherwise would mean inventing a ranking out of orbital elements, which
    /// says nothing about whether a person has heard of the object.
    static let notableCatalogNumbers: Set<Int> = [
        25544, // ISS (ZARYA)
        20580, // Hubble Space Telescope
        48274, // CSS (TIANHE) — Chinese Space Station core module
        53239, // CSS (WENTIAN)
        54216, // CSS (MENGTIAN)
        25994, // Terra
        27424, // Aqua
        27386, // Envisat
        39084, // Landsat 8
        49260, // Landsat 9
        25338, // NOAA 15
        28654, // NOAA 18
        33591, // NOAA 19
        43013, // NOAA 20 (JPSS-1)
        37849, // Suomi NPP
        29499, // MetOp-A
        38771, // MetOp-B
        43689, // MetOp-C
        40069, // Meteor M2
        41866, // GOES 16
        43226, // GOES 17
        51850, // GOES 18
    ]
}

/// One satellite's propagated state at a tick, in a form the renderer can copy
/// cheaply and extrapolate between ticks.
///
/// Everything here is a plain value: the renderer must never reach back into a
/// `Satellite` (and therefore into a propagator being mutated on a background
/// actor) while drawing a frame.
struct SatelliteSample: Sendable {
    /// Index into the tracker's `descriptors` array, which carries the name and
    /// the other rarely-needed identity fields. Keeping them out of the sample
    /// matters: this struct is copied 16,000 times per tick, and a `String`
    /// field would mean 16,000 retain/release pairs for data the renderer needs
    /// for at most a few dozen labels.
    let index: Int
    let catalogNumber: Int
    let regime: OrbitalRegime
    let isNotable: Bool

    /// Geocentric TEME position at the snapshot's epoch, in kilometres.
    let position: SIMD3<Double>
    /// Geocentric TEME velocity, in kilometres per second. This is what makes
    /// smooth motion possible without re-propagating: over a fraction of a
    /// second, `position + velocity * dt` is accurate to metres.
    let velocity: SIMD3<Double>

    /// Whether the satellite is in sunlight, computed once per tick.
    let illumination: TopocentricTransform.Illumination

    /// Altitude above the horizon at the snapshot's epoch, in degrees. Used
    /// only as a *coarse* pre-filter by the geometry builder; the drawn
    /// position is always recomputed from the extrapolated state.
    let altitudeDegreesAtSnapshot: Double
}

/// The identity half of a satellite, as a plain value that can cross actor
/// boundaries. Loaded once and never mutated, unlike `Satellite` whose
/// propagator carries integration state.
struct SatelliteDescriptor: Hashable, Sendable, Identifiable {
    let catalogNumber: Int
    let name: String
    let regime: OrbitalRegime
    let internationalDesignator: String
    let epochJulianDay: Double
    let isNotable: Bool

    var id: String { "sat-\(catalogNumber)" }

    init(
        catalogNumber: Int, name: String, regime: OrbitalRegime,
        internationalDesignator: String, epochJulianDay: Double, isNotable: Bool
    ) {
        self.catalogNumber = catalogNumber
        self.name = name
        self.regime = regime
        self.internationalDesignator = internationalDesignator
        self.epochJulianDay = epochJulianDay
        self.isNotable = isNotable
    }

    init(_ satellite: Satellite) {
        catalogNumber = satellite.catalogNumber
        name = satellite.name
        regime = satellite.regime
        internationalDesignator = satellite.internationalDesignator
        epochJulianDay = satellite.epochJulianDay
        isNotable = satellite.isNotable
    }

    /// Age of the element set, in days, at the given time. Positive means the
    /// elements are older than the moment being displayed.
    func elementSetAgeDays(atJulianDay jd: Double) -> Double {
        jd - epochJulianDay
    }
}

/// One complete propagation tick: every satellite's state at one instant.
struct SatelliteSnapshot: Sendable {
    /// Julian Day the samples are valid for.
    let julianDay: Double
    /// Ordered by ascending `SatelliteSample.index` — the tracker builds them
    /// that way, and `sample(descriptorIndex:)` relies on it.
    let samples: [SatelliteSample]
    /// Wall-clock duration of the propagation pass, for the performance
    /// reporting in `SkyViewModel`.
    let propagationDuration: TimeInterval

    static let empty = SatelliteSnapshot(julianDay: 0, samples: [], propagationDuration: 0)

    /// Finds a sample by its descriptor index.
    ///
    /// A binary search rather than a scan because the caller is the selected
    /// satellite's per-frame refresh: at 120 Hz a linear pass over sixteen
    /// thousand samples would be two million comparisons a second to keep one
    /// info panel current.
    func sample(descriptorIndex: Int) -> SatelliteSample? {
        var low = 0
        var high = samples.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let candidate = samples[mid].index
            if candidate == descriptorIndex { return samples[mid] }
            if candidate < descriptorIndex { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }
}
