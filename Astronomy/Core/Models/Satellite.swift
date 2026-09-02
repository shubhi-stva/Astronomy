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
///
/// `nonisolated` because the target's default isolation is `MainActor`, and
/// this type is the opposite of main-actor work: sixteen thousand of them are
/// created, mutated and released on `SatelliteTracker`'s executor and its task
/// group. Left implicit, every one of them would carry a main-actor-isolated
/// deinit, so releasing the catalogue off the main thread would hop sixteen
/// thousand times through the concurrency runtime.
nonisolated final class Satellite: @unchecked Sendable {

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
    ///
    /// Every entry was checked against the bundled snapshot: retired objects
    /// (Envisat, the older NOAA and MetOp satellites) have left CelesTrak's
    /// "active" group and were removed rather than left here to match nothing.
    /// An unmatched entry is harmless but silently useless, which is worse than
    /// a shorter list.
    /// The International Space Station. Singled out because it is the one
    /// object in the catalogue everybody wants named on sight: it carries a
    /// label whenever it is on screen, at full strength, regardless of
    /// selection or of how dim the pass happens to be.
    static let issCatalogNumber = 25544

    static let notableCatalogNumbers: Set<Int> = [
        25544, // ISS (ZARYA)
        20580, // Hubble Space Telescope
        48274, // CSS (TIANHE) — Chinese Space Station core module
        53239, // CSS (WENTIAN)
        54216, // CSS (MENGTIAN)
        25994, // Terra
        27424, // Aqua
        39084, // Landsat 8
        49260, // Landsat 9
        43013, // NOAA 20 (JPSS-1)
        37849, // Suomi NPP
        38771, // MetOp-B
        43689, // MetOp-C
        40069, // Meteor M2
        41866, // GOES 16
        43226, // GOES 17
        51850, // GOES 18
        54234, // NOAA 21 (JPSS-2)
        40697, // Sentinel-2A
    ]
}

/// How far from its element-set epoch an SGP4 propagation may be trusted, and
/// what the app does about it.
///
/// **This is the hard accuracy limit of the whole satellite layer, and it is
/// the reason the time machine cannot simply run satellites forward.**
///
/// SGP4 is not an ephemeris. It is a fit: a TLE encodes mean elements plus a
/// drag term tuned so the model reproduces the observed orbit *near its
/// epoch*. Away from that epoch the fit degrades fast, and in low orbit the
/// dominant error is atmospheric drag, whose actual magnitude depends on solar
/// and geomagnetic activity nobody encoded in the two lines. The operational
/// rule of thumb — and CelesTrak's own guidance — is roughly a kilometre of
/// along-track error per day for a typical LEO object, growing worse than
/// linearly, and far worse during a geomagnetic storm.
///
/// A kilometre at 500 km range is about 0.1 degrees, so a few days is where the
/// prediction stops being pixel-accurate. At one month it is hundreds to
/// thousands of kilometres: the satellite is somewhere in its orbital plane,
/// and the app has no idea where. That is not "imprecise", it is *meaningless* —
/// a position drawn from it would be indistinguishable from a random point
/// along the ground track.
///
/// There are therefore **two different questions**, and the app answers them
/// differently:
///
///  1. *"The user is looking at the real sky right now, and the newest elements
///     the app could get hold of are a week old."* Hiding the satellites here
///     is the wrong answer — the objects are up there, the app knows roughly
///     where, and a marker that is a degree off is still the difference between
///     "that moving dot is the ISS" and no answer at all. So they are drawn,
///     **and the degradation is stated** (see `ElementSetStaleness`), never
///     passed off as precision the app does not have.
///  2. *"The user has scrubbed simulated time a month away."* Here there is
///     nothing to be honest about: SGP4 genuinely does not know where the
///     object is along its plane. The app refuses to draw it.
///
/// `isDrawable` is the one gate, and it encodes exactly that split.
enum SatelliteAccuracy {

    /// Half-width, in days, of the window either side of an element-set epoch
    /// in which a *simulated* instant is still worth propagating to. Five days
    /// is deliberately at the generous end of "a few days": inside it a LEO
    /// object is typically within a few kilometres, so the marker is in the
    /// right part of the sky even if the exact pass timing has slipped by
    /// seconds.
    static let maximumElementSetAgeDays: Double = 5.0

    /// Half-width, in days, of the window around *real* time in which the app
    /// draws satellites whatever the age of its elements.
    ///
    /// This is the "problem 1" case above. Within ±5 days of now the user is
    /// looking at something they can actually check against the sky, so the
    /// app shows its best estimate and labels how good it is, rather than
    /// showing nothing.
    static let realTimeWindowDays: Double = 5.0

    /// Whether a propagation at `julianDay` from `epochJulianDay` is close
    /// enough to the epoch to be worth drawing on its own merits. Symmetric:
    /// elements are no more valid five days *before* their epoch than after.
    static func isReliable(julianDay: Double, epochJulianDay: Double) -> Bool {
        abs(julianDay - epochJulianDay) <= maximumElementSetAgeDays
    }

    /// Whether the displayed instant counts as "real time" — i.e. the user is
    /// looking at the sky as it is now, not scrubbing the time machine.
    static func isNearRealTime(julianDay: Double, nowJulianDay: Double) -> Bool {
        abs(julianDay - nowJulianDay) <= realTimeWindowDays
    }

    /// **The single gate.** A satellite is drawn when either
    ///
    ///  * the displayed instant is within `realTimeWindowDays` of real time —
    ///    aging elements degrade the answer but do not delete it, and the UI
    ///    says so; or
    ///  * the displayed instant is within `maximumElementSetAgeDays` of the
    ///    element epoch, which is the case that keeps short scrubs working with
    ///    fresh elements.
    ///
    /// Scrubbing far from *both* — the month-out time machine — draws nothing.
    static func isDrawable(
        julianDay: Double, nowJulianDay: Double, epochJulianDay: Double
    ) -> Bool {
        isNearRealTime(julianDay: julianDay, nowJulianDay: nowJulianDay)
            || isReliable(julianDay: julianDay, epochJulianDay: epochJulianDay)
    }

    /// Classifies element-set age for display. See `ElementSetStaleness`.
    static func staleness(ageDays: Double) -> ElementSetStaleness {
        let age = abs(ageDays)
        if age <= ElementSetStaleness.freshLimitDays { return .fresh }
        if age <= ElementSetStaleness.agingLimitDays { return .aging }
        return .unreliable
    }
}

/// How much to trust a drawn satellite position, as a function of how old its
/// element set is.
///
/// The thresholds come from how SGP4 error actually grows. The dominant term in
/// low orbit is along-track: the object is in very nearly the right *plane* but
/// increasingly wrong about *where along it*, because the drag term in the two
/// lines was fitted to a past atmosphere. The operational rule of thumb is of
/// order one to three kilometres of along-track error per day for a typical LEO
/// object, growing faster than linearly and much faster through a geomagnetic
/// storm.
///
/// Turning that into what a user sees, for a 400–600 km pass at a few hundred
/// to ~1500 km slant range:
///
///  * **≤ 2 days — fresh.** A few kilometres at worst. A LEO object moves at
///    ~7.7 km/s, so that is well under a second of pass timing; on the sky it
///    is a few tenths of a degree, comparable to the marker itself. Drawn with
///    no warning, because there is nothing worth warning about.
///  * **2–10 days — aging.** Of order 10–30 km along-track. That is seconds of
///    timing error and, at a close overhead pass, up to a few degrees of sky
///    position — enough to matter when you are pointing at the thing, not
///    enough to make the identification wrong. Drawn, and labelled as aging.
///  * **> 10 days — unreliable.** Tens to hundreds of kilometres, growing
///    non-linearly, and a pass may be minutes early or late. The orbital
///    *plane* is still about right, so the track across the sky still means
///    something; the position along it does not. Drawn, and plainly flagged.
///
/// The boundaries are judgement calls at the edges of a spread that depends on
/// solar activity and on the individual object's ballistic coefficient. They
/// are chosen to be conservative: an object called "fresh" here really is
/// pixel-accurate, and one called "aging" really is still useful.
enum ElementSetStaleness: Comparable, Sendable {
    case fresh
    case aging
    case unreliable

    static let freshLimitDays: Double = 2.0
    static let agingLimitDays: Double = 10.0

    /// Short qualifier for the info panel's element-set row.
    var shortLabel: String? {
        switch self {
        case .fresh: return nil
        case .aging: return "aging"
        case .unreliable: return "unreliable"
        }
    }

    /// One sentence saying what this staleness means for what is on screen.
    /// `nil` for fresh elements, where there is nothing to say.
    var caveat: String? {
        switch self {
        case .fresh:
            return nil
        case .aging:
            return "Positions are approximate: pass times may be off by seconds and positions by up to a degree or so."
        case .unreliable:
            return "Positions are unreliable: the orbit is about right, but where the satellite is along it may be minutes — and many degrees — out."
        }
    }
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

    /// How much of the Sun is still uncovered at this satellite, from 1 in full
    /// sunlight to 0 in the umbra — the continuous form of `illumination`.
    ///
    /// This is what a pass fades out *along*. The three-way state alone forces
    /// the renderer to switch a satellite off at the first non-sunlit tick,
    /// which — since the penumbra crossing takes eight to twelve seconds —
    /// deletes the marker at the start of the fade instead of during it. That
    /// read, correctly, as satellites disappearing.
    ///
    /// A `Float`, and declared here rather than at the end, so it lands in the
    /// padding that already followed `isNotable`: `SatelliteSample` is copied
    /// sixteen thousand times per tick and walked every frame, and this must
    /// not make the record any bigger. `SatelliteSampleLayoutTests` pins that.
    let sunlitFraction: Float

    /// This object's element-set epoch as a Julian Day. Carried in the sample
    /// (a bare `Double`, so it costs nothing to copy) rather than looked up in
    /// the descriptor array, because `SatelliteAccuracy` has to gate *before*
    /// any trigonometry: the descriptor lookup is deliberately deferred until
    /// after every rejection in the geometry builder.
    let epochJulianDay: Double

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

    /// Written out rather than left to the memberwise initialiser so
    /// `sunlitFraction` can sit where the layout wants it (in the padding after
    /// `isNotable`) while still being the *last* argument, defaulted from the
    /// three-way state. Every caller that only knows the enum — the tests, and
    /// anything hand-building a snapshot — keeps working and gets a fraction
    /// consistent with it.
    init(
        index: Int,
        catalogNumber: Int,
        regime: OrbitalRegime,
        isNotable: Bool,
        epochJulianDay: Double,
        position: SIMD3<Double>,
        velocity: SIMD3<Double>,
        illumination: TopocentricTransform.Illumination,
        altitudeDegreesAtSnapshot: Double,
        sunlitFraction: Float? = nil
    ) {
        self.index = index
        self.catalogNumber = catalogNumber
        self.regime = regime
        self.isNotable = isNotable
        self.epochJulianDay = epochJulianDay
        self.position = position
        self.velocity = velocity
        self.illumination = illumination
        self.altitudeDegreesAtSnapshot = altitudeDegreesAtSnapshot
        self.sunlitFraction = sunlitFraction ?? {
            switch illumination {
            case .sunlit: return 1.0
            case .penumbra: return 0.5
            case .umbra: return 0.0
            }
        }()
    }
}

/// The *end* of the interval a sample covers: where the propagator says the
/// satellite will be one tick after the snapshot, propagated exactly rather
/// than extrapolated.
///
/// Kept in a **parallel array** on the snapshot rather than as two more fields
/// on `SatelliteSample`, and that is not a stylistic choice. The geometry
/// builder walks the sample array every frame to find the few objects that
/// could be on screen; widening that record by 64 bytes would slow the
/// wide-field scan for the sake of data only a narrow field ever reads. As a
/// side array it is allocated only when the camera is zoomed in far enough to
/// need it, and touched only for the handful of satellites actually drawn.
struct SatelliteSubTickState: Sendable {
    /// Geocentric TEME position one sub-tick interval after the snapshot, km.
    let position: SIMD3<Double>
    /// Geocentric TEME velocity at that instant, km/s.
    let velocity: SIMD3<Double>
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

    /// Indices into `samples`, ordered by ascending
    /// `altitudeDegreesAtSnapshot`.
    ///
    /// A separate ordering rather than sorting `samples` itself, because
    /// `sample(descriptorIndex:)` depends on that array staying index-ordered.
    ///
    /// This exists so the renderer does not have to look at every satellite
    /// every frame. The geometry builder only draws objects within a band of
    /// altitudes around where the camera is pointing, and with this it can
    /// binary-search straight to that band: at a typical field that is a few
    /// hundred candidates instead of all sixteen thousand, on the main thread,
    /// sixty times a second. Built once per propagation tick on a background
    /// actor, where a sort of this size costs nothing anyone can feel.
    /// Empty is a valid state and means "no ordering available": the renderer
    /// falls back to scanning every sample, which is correct, just slower. That
    /// keeps hand-built snapshots in tests working without having to sort.
    let altitudeOrder: [Int32]

    /// Exact propagated state one `subTickIntervalSeconds` after `julianDay`,
    /// parallel to `samples`.
    ///
    /// **This is what makes a zoomed-in satellite stop jumping.** Between ticks
    /// the renderer normally draws `r + v·dt`, which is wrong by a few metres
    /// by the end of a tick — nothing at a 90-degree field, several pixels at
    /// the 0.15-degree limit the camera now allows. With the end of the
    /// interval in hand as well, the renderer can interpolate on a cubic
    /// Hermite through *both* endpoints instead of extrapolating from one, and
    /// the drawn position then arrives at the next snapshot's own position
    /// exactly. There is no correction left to make, so there is no step to
    /// see.
    ///
    /// Empty means the pass was not run, which is the normal state: it is
    /// computed only when the camera is zoomed in far enough for the
    /// extrapolation error to be worth a pixel (see
    /// `SatelliteSubTick.isWorthComputing`). At a wide field this costs
    /// nothing anywhere — no second propagation on the tracker, no extra bytes
    /// in the array the frame path scans, no branch taken in the draw loop.
    let subTickStates: [SatelliteSubTickState]

    /// Interval, in seconds, between `julianDay` and the instant
    /// `subTickStates` were propagated to. Zero when there are none.
    let subTickIntervalSeconds: Double

    /// True when this snapshot carries a usable exact end-of-interval state.
    var hasSubTickStates: Bool {
        subTickIntervalSeconds > 0 && subTickStates.count == samples.count
    }

    init(
        julianDay: Double,
        samples: [SatelliteSample],
        propagationDuration: TimeInterval,
        altitudeOrder: [Int32] = [],
        subTickStates: [SatelliteSubTickState] = [],
        subTickIntervalSeconds: Double = 0
    ) {
        self.julianDay = julianDay
        self.samples = samples
        self.propagationDuration = propagationDuration
        self.altitudeOrder = altitudeOrder
        self.subTickStates = subTickStates
        self.subTickIntervalSeconds = subTickIntervalSeconds
    }

    static let empty = SatelliteSnapshot(
        julianDay: 0, samples: [], propagationDuration: 0
    )

    /// The slice of `altitudeOrder` whose samples lie within `halfWidth`
    /// degrees of `centre`. Both bounds found by binary search.
    func altitudeOrderRange(centre: Double, halfWidth: Double) -> Range<Int> {
        let low = lowerBound(altitude: centre - halfWidth)
        let high = lowerBound(altitude: centre + halfWidth.nextUp)
        return low..<max(low, high)
    }

    /// First position in `altitudeOrder` whose sample altitude is >= `altitude`.
    private func lowerBound(altitude: Double) -> Int {
        var low = 0
        var high = altitudeOrder.count
        while low < high {
            let mid = (low + high) / 2
            if samples[Int(altitudeOrder[mid])].altitudeDegreesAtSnapshot < altitude {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

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
