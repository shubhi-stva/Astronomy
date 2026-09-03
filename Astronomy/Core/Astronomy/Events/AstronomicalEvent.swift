//
//  AstronomicalEvent.swift
//  Astronomy
//
//  One entry in the sky calendar.
//
//  Every event here is either **computed** from the app's own ephemeris by
//  solving an equation (moon phases, equinoxes and solstices, oppositions and
//  conjunctions, close approaches) or **tabulated** from a published source and
//  then anchored in time by a computation (meteor showers, whose maxima the IMO
//  publishes as solar longitudes, which this app solves for). `provenance` says
//  which, per event, because the two deserve different amounts of trust and the
//  UI shows the distinction rather than hiding it.
//
//  What is deliberately absent is eclipses — see `DATA_SOURCES.md`, and the
//  note on `AstronomicalEventKind`.
//

import Foundation

/// Where an event's numbers come from.
enum EventProvenance: String, Hashable, Sendable {
    /// Solved from the app's own Sun/Moon/planet ephemerides.
    case computed
    /// The date is solved, but the event's identity and its numbers (radiant,
    /// rate) come from a published table. See `MeteorShowers`.
    case tabulated
}

enum AstronomicalEventKind: String, Hashable, Sendable, CaseIterable {
    case moonPhase
    case season
    case opposition
    case conjunction
    case greatestElongation
    case closeApproach
    case meteorShower

    // Note the absence of `eclipse`. Solar-eclipse local circumstances need a
    // lunar ephemeris an order of magnitude better than the truncated ELP
    // series here, plus Besselian elements and a figure of the Earth; getting
    // it approximately right would produce times that look authoritative and
    // are not, for the one class of event people book travel around. Omitted on
    // purpose rather than shipped approximate.

    var displayName: String {
        switch self {
        case .moonPhase: return "Moon phase"
        case .season: return "Season"
        case .opposition: return "Opposition"
        case .conjunction: return "Conjunction"
        case .greatestElongation: return "Greatest elongation"
        case .closeApproach: return "Close approach"
        case .meteorShower: return "Meteor shower"
        }
    }

    /// SF Symbol shown beside the event in the calendar.
    var symbolName: String {
        switch self {
        case .moonPhase: return "moonphase.waxing.gibbous"
        case .season: return "sun.max"
        case .opposition: return "circle.lefthalf.filled"
        case .conjunction: return "circle.grid.2x1"
        case .greatestElongation: return "arrow.left.and.right"
        case .closeApproach: return "circle.circle"
        case .meteorShower: return "sparkles"
        }
    }
}

/// How well an event can be observed from a particular place, expressed in the
/// terms the rest of the app already uses.
///
/// This is a *report* of the existing rise/set and visibility machinery, not a
/// second model: `peak` comes from `RiseSetCalculator`, and `band` is
/// `VisibilityRating.altitudeBand` applied to it. Events with nothing to point
/// at (an equinox, a conjunction with the Sun) carry `nil` here rather than a
/// fabricated rating.
struct EventObservability: Hashable, Sendable {
    /// Altitude of the event's target at the moment the event happens.
    let altitudeAtEventDegrees: Double
    /// Highest the target gets during the night the event falls in.
    let peakAltitudeDegrees: Double
    /// When that peak occurs.
    let peakJulianDay: Double
    let circumstance: RiseSetCalculator.Circumstance
    /// True when the peak above falls inside astronomical darkness.
    let peakIsInDarkness: Bool
    let band: VisibilityBand

    var isUpAtEvent: Bool { altitudeAtEventDegrees > 0 }
}

struct AstronomicalEvent: Identifiable, Hashable, Sendable {
    let id: String
    let kind: AstronomicalEventKind
    let provenance: EventProvenance
    /// The instant, as a Julian Day. This is what the Time Machine jumps to.
    let julianDay: Double
    /// Short name: "Full Moon", "Perseids", "Mars at opposition".
    let title: String
    /// One sentence of substance — the number that makes the event worth
    /// knowing about, not a restatement of the title.
    let detail: String
    /// The object to select when the event is opened, if there is one.
    let targetObjectID: String?
    /// Where to look, in equatorial coordinates *of date*, if there is a where.
    let targetEquatorial: EquatorialCoordinate?
    /// Filled in by `EventCalendar` once an observer is known.
    var observability: EventObservability?

    var date: Date { JulianDate.date(fromJulianDay: julianDay) }
}
