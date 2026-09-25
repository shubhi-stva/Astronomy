//
//  PaletteCommand.swift
//  Astronomy
//
//  What a command palette row *is*, and what choosing it does.
//
//  The action is a value, not a closure. That is the single most important
//  decision in this file: a `() -> Void` would make every command untestable
//  without a running app and a main actor, and the palette's whole risk is that
//  a command silently does the wrong thing. As an enum, "typing 'grid' and
//  pressing return toggles the equatorial grid" is one synchronous assertion.
//  `SkyViewModel.perform(_:)` is the only place that turns an action into an
//  effect, so there is exactly one place to look when one misbehaves.
//

import Foundation

/// The sky layers the palette can switch.
enum SkyLayer: String, CaseIterable, Hashable, Sendable {
    case constellationLines
    case deepSky
    case equatorialGrid
    case horizontalGrid
    case ecliptic
    case meridian
    case constellationBoundaries
    case meteorRadiants
    case planetMoons
    case refraction
    case satellites
    case allSatellites

    var displayName: String {
        switch self {
        case .constellationLines: return "constellation lines"
        case .deepSky: return "deep-sky objects"
        case .equatorialGrid: return "the equatorial grid"
        case .horizontalGrid: return "the horizon grid"
        case .ecliptic: return "the ecliptic"
        case .meridian: return "the meridian"
        case .constellationBoundaries: return "constellation boundaries"
        case .meteorRadiants: return "meteor shower radiants"
        // "the Galilean moons", not "the moons of Jupiter": the standard name,
        // and it keeps the bare word "jupiter" meaning the planet in search.
        // Named the other way, this layer outranked Jupiter itself for the
        // query "jupiter", because a layer outweighs an object on a comparable
        // textual match.
        case .planetMoons: return "the Galilean moons"
        case .refraction: return "atmospheric refraction"
        case .satellites: return "satellites"
        case .allSatellites: return "all satellites"
        }
    }

    /// Words a user might reach for that are not in the display name.
    var aliases: [String] {
        switch self {
        case .constellationLines: return ["constellations", "figures", "asterisms", "stick figures"]
        case .deepSky: return ["nebulae", "galaxies", "clusters", "messier", "ngc", "dso"]
        case .equatorialGrid: return ["grid", "graticule", "ra dec", "coordinates", "equatorial"]
        case .horizontalGrid: return ["alt az", "altitude azimuth", "horizon", "altaz grid"]
        case .ecliptic: return ["zodiac", "path of the sun", "ecliptic line"]
        case .meridian: return ["local meridian", "transit line", "north south line"]
        case .constellationBoundaries: return ["borders", "boundaries", "iau boundaries", "constellation borders"]
        case .meteorRadiants: return ["meteors", "radiants", "showers", "perseids", "geminids"]
        case .planetMoons: return ["galilean moons", "io", "europa", "ganymede", "callisto", "jupiter moons", "moons"]
        case .refraction: return ["refraction", "atmosphere", "horizon lift"]
        case .satellites: return ["iss", "orbit", "spacecraft"]
        case .allSatellites: return ["every satellite", "whole catalogue", "debris"]
        }
    }

    var symbolName: String {
        switch self {
        case .constellationLines: return "line.diagonal"
        case .deepSky: return "hurricane"
        case .equatorialGrid: return "grid"
        case .horizontalGrid: return "square.grid.3x3.middle.filled"
        case .ecliptic: return "sun.max"
        case .meridian: return "arrow.up.and.down"
        case .constellationBoundaries: return "squareshape.split.3x3"
        case .meteorRadiants: return "sparkles"
        case .planetMoons: return "circles.hexagonpath"
        case .refraction: return "water.waves"
        case .satellites: return "antenna.radiowaves.left.and.right"
        case .allSatellites: return "square.grid.3x3"
        }
    }
}

/// The two floating dashboards.
enum PalettePanel: String, CaseIterable, Hashable, Sendable {
    case tonight
    case calendar

    var displayName: String {
        switch self {
        case .tonight: return "Tonight"
        case .calendar: return "Calendar"
        }
    }
}

/// Time-machine destinations and controls.
enum PaletteTimeAction: Hashable, Sendable {
    /// Back to the real clock at 1×.
    case now
    /// Midnight at the start of the coming night, local time.
    case midnight
    /// The start of tonight's astronomical darkness, or nautical dusk where
    /// there is none.
    case tonight
    case sunset
    case sunrise
    case togglePlaying
    case setRate(TimeController.PlaybackRate)
    case shiftHours(Int)
    case shiftDays(Int)
}

/// Everything choosing a palette row can do.
enum PaletteAction: Hashable, Sendable {
    /// Fly to and select a catalogue or solar-system object.
    case focus(CelestialObject)
    case toggleLayer(SkyLayer)
    case toggleNightVision
    case togglePanel(PalettePanel)
    case time(PaletteTimeAction)
    /// Move the time machine to an event and look at it.
    case jumpToEvent(AstronomicalEvent)
    /// Switch the palette into location-entry mode, where the query is
    /// geocoded instead of matched against commands.
    case beginLocationEntry
    case setLocation(name: String, latitudeDegrees: Double, longitudeDegrees: Double)
    /// Light pollution, as a Bortle class 1...9.
    case setBortleClass(Int)
    /// Show one field-of-view circle of the given true field, or none.
    case setFieldOfViewCircle(FieldOfViewPreset?)
    /// Start measuring from the selected object; the next click finishes.
    case beginMeasure
    case clearMeasure
    /// Open the satellite pass list for the selected (or notable) satellite.
    case togglePassesPanel
}

/// Eyepiece and binocular fields the overlay can draw.
enum FieldOfViewPreset: String, CaseIterable, Hashable, Sendable {
    case binoculars7x50
    case binoculars10x50
    case finderScope
    case eyepieceWide
    case eyepieceMedium
    case eyepieceHigh
    case moonWidth

    var displayName: String {
        switch self {
        case .binoculars7x50: return "7×50 binoculars"
        case .binoculars10x50: return "10×50 binoculars"
        case .finderScope: return "finder scope"
        case .eyepieceWide: return "low-power eyepiece"
        case .eyepieceMedium: return "medium-power eyepiece"
        case .eyepieceHigh: return "high-power eyepiece"
        case .moonWidth: return "one Moon diameter"
        }
    }

    /// True field of view, degrees.
    var fieldDegrees: Double {
        switch self {
        case .binoculars7x50: return 7.0
        case .binoculars10x50: return 6.5
        case .finderScope: return 5.0
        case .eyepieceWide: return 2.0
        case .eyepieceMedium: return 0.8
        case .eyepieceHigh: return 0.33
        case .moonWidth: return 0.52
        }
    }
}

/// The class a row belongs to. Used for the section label, and for the weight
/// that keeps eighty star matches from burying a setting the user asked for.
enum PaletteCategory: String, CaseIterable, Hashable, Sendable {
    case object
    case layer
    case time
    case event
    case location
    case tool

    var displayName: String {
        switch self {
        case .object: return "Sky"
        case .layer: return "Layers"
        case .time: return "Time"
        case .event: return "Events"
        case .location: return "Location"
        case .tool: return "Tools"
        }
    }

    /// Multiplier applied to a row's match score.
    ///
    /// Actions outrank objects on an equal textual match, deliberately. A
    /// palette exists to do things; the search bar already exists to find
    /// things, and a user who wanted the star typed it there. The weights are
    /// close enough that a *much* better textual match still wins — "betelgeu"
    /// finds the star despite the star's lower weight.
    var weight: Double {
        switch self {
        // Time above layers, and that ordering settles one real collision:
        // "tonight" matches both "Jump to tonight" and "Open Tonight". Moving
        // the time machine is the more consequential of the two and the harder
        // one to reach any other way — the panel also has a pill in the chrome.
        case .time: return 1.3
        case .layer: return 1.25
        case .location: return 1.15
        case .event: return 1.1
        case .tool: return 1.2
        case .object: return 1.0
        }
    }
}

struct PaletteCommand: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    /// The quiet second line: what the command will do, or what the object is.
    let subtitle: String?
    let symbolName: String
    let category: PaletteCategory
    /// Extra strings that also match. Never shown.
    let aliases: [String]
    let action: PaletteAction
    /// Score assigned by `CommandProvider` for the query that produced it.
    var score: Double = 0
}
