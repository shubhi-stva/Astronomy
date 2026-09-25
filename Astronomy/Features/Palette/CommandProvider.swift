//
//  CommandProvider.swift
//  Astronomy
//
//  Turns a query and a snapshot of app state into a ranked list of commands.
//
//  Pure, synchronous, and free of SwiftUI, Observation and the main actor. That
//  is what makes the palette's behaviour — which command a query produces, and
//  in what order — something tests can assert directly rather than something a
//  human has to try.
//
//  The expensive inputs (object matches, upcoming events, geocoded places) are
//  *passed in* rather than fetched here. The view model already owns a search
//  index and a calendar and must not grow a second of either; and asking this
//  function to do I/O would make it exactly as untestable as a closure-based
//  design would have.
//

import Foundation

/// Everything the provider needs to know about the app, as plain data.
struct PaletteContext: Sendable {

    struct Place: Hashable, Sendable {
        let name: String
        let latitudeDegrees: Double
        let longitudeDegrees: Double
    }

    /// Current on/off state of each layer, so the commands can read
    /// "Hide the coordinate grid" rather than "Toggle grid".
    var layers: [SkyLayer: Bool] = [:]
    var isNightVisionEnabled: Bool = false
    var openPanels: Set<PalettePanel> = []
    /// Matches from the app's existing search index. Never recomputed here.
    var objectMatches: [CelestialObject] = []
    /// The calendar's events, when it has them.
    var upcomingEvents: [AstronomicalEvent] = []
    /// Geocoder results — populated only in location mode.
    var placeMatches: [Place] = []
    /// True once "Set location…" has been chosen: the query is a place name.
    var isLocationMode: Bool = false
    /// Current light-pollution setting.
    var bortleClass: Int = 3
    /// Whether a field-of-view circle is showing.
    var hasFieldOfViewCircle: Bool = false
    /// Whether something is selected (the measure tool needs an anchor).
    var hasSelection: Bool = false
    var isMeasuring: Bool = false
    var isPassesPanelOpen: Bool = false

    init() {}
}

enum CommandProvider {

    /// How many object matches the palette will show. Small on purpose: the
    /// search bar is the place for a long list, and a palette that fills with
    /// twenty stars has stopped being a palette.
    static let objectLimit = 6
    /// How many upcoming events can appear at once.
    static let eventLimit = 5
    /// Total rows. Beyond about a dozen the list stops being scannable and the
    /// keyboard-only user is arrowing through noise.
    static let resultLimit = 12

    /// The ranked commands for a query.
    static func commands(query: String, context: PaletteContext) -> [PaletteCommand] {
        if context.isLocationMode {
            return locationCommands(context: context)
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = allCandidates(context: context)

        guard !trimmed.isEmpty else {
            // An empty query shows the useful defaults in declared order: the
            // things a user opens the palette to do without knowing their name.
            return Array(candidates.filter { $0.category != .object }.prefix(resultLimit))
        }

        var scored: [PaletteCommand] = []
        for candidate in candidates {
            guard let score = FuzzyMatch.bestScore(
                query: trimmed, title: candidate.title, aliases: candidate.aliases
            ) else { continue }
            var command = candidate
            command.score = score * candidate.category.weight
            scored.append(command)
        }
        // Sort is stable on the score, then on title length so a tie goes to
        // the shorter — i.e. the less padded — of two equally good matches.
        scored.sort {
            $0.score != $1.score ? $0.score > $1.score : $0.title.count < $1.title.count
        }
        return Array(scored.prefix(resultLimit))
    }

    // MARK: - Candidates

    static func allCandidates(context: PaletteContext) -> [PaletteCommand] {
        var commands: [PaletteCommand] = []
        commands += layerCommands(context: context)
        commands += nightVisionCommand(context: context)
        commands += panelCommands(context: context)
        commands += timeCommands()
        commands += locationEntryCommand()
        commands += toolCommands(context: context)
        commands += eventCommands(context: context)
        commands += objectCommands(context: context)
        return commands
    }

    static func layerCommands(context: PaletteContext) -> [PaletteCommand] {
        SkyLayer.allCases.map { layer in
            let isOn = context.layers[layer] ?? false
            return PaletteCommand(
                id: "layer-\(layer.rawValue)",
                // Named by what choosing it *does*, not by the layer's state.
                // "Toggle grid" makes the user find out by trying.
                title: "\(isOn ? "Hide" : "Show") \(layer.displayName)",
                subtitle: isOn ? "Currently shown" : "Currently hidden",
                symbolName: layer.symbolName,
                category: .layer,
                // Both verbs are aliases, so typing "show grid" finds the row
                // even when the row currently reads "Hide the coordinate grid".
                aliases: layer.aliases.flatMap { ["show \($0)", "hide \($0)", $0] }
                    + ["toggle \(layer.displayName)"],
                action: .toggleLayer(layer)
            )
        }
    }

    /// Bortle scale descriptions, index 1...9.
    static let bortleNames = [
        "", "excellent dark sky", "truly dark sky", "rural sky", "rural/suburban transition",
        "suburban sky", "bright suburban sky", "suburban/urban transition", "city sky", "inner-city sky",
    ]

    static func toolCommands(context: PaletteContext) -> [PaletteCommand] {
        var commands: [PaletteCommand] = []
        for bortle in 1...9 where bortle != context.bortleClass {
            commands.append(PaletteCommand(
                id: "bortle-\(bortle)",
                title: "Set light pollution to Bortle \(bortle)",
                subtitle: bortleNames[bortle].prefix(1).uppercased() + bortleNames[bortle].dropFirst()
                    + " (now Bortle \(context.bortleClass))",
                symbolName: "lightbulb.max",
                category: .tool,
                aliases: ["bortle \(bortle)", "light pollution \(bortle)", bortleNames[bortle], "sky quality", "bortle"],
                action: .setBortleClass(bortle)
            ))
        }
        for preset in FieldOfViewPreset.allCases {
            commands.append(PaletteCommand(
                id: "fov-\(preset.rawValue)",
                title: "Show a \(preset.displayName) field circle",
                subtitle: "\(preset.fieldDegrees.formatted(.number.precision(.fractionLength(0...2))))° true field, centred on the view",
                symbolName: "scope",
                category: .tool,
                aliases: ["fov", "field of view", "eyepiece", "binoculars", "telescope", preset.displayName],
                action: .setFieldOfViewCircle(preset)
            ))
        }
        if context.hasFieldOfViewCircle {
            commands.append(PaletteCommand(
                id: "fov-clear",
                title: "Hide the field circle",
                subtitle: "Remove the field-of-view overlay",
                symbolName: "scope",
                category: .tool,
                aliases: ["fov", "field of view", "clear field", "remove circle"],
                action: .setFieldOfViewCircle(nil)
            ))
        }
        if context.isMeasuring {
            commands.append(PaletteCommand(
                id: "measure-clear",
                title: "Stop measuring",
                subtitle: "Remove the angular-distance line",
                symbolName: "ruler",
                category: .tool,
                aliases: ["measure", "distance", "separation", "angle", "ruler"],
                action: .clearMeasure
            ))
        } else if context.hasSelection {
            commands.append(PaletteCommand(
                id: "measure",
                title: "Measure from the selected object",
                subtitle: "Then click a second object to read the angular distance (M)",
                symbolName: "ruler",
                category: .tool,
                aliases: ["measure", "distance", "separation", "angle", "ruler", "angular distance"],
                action: .beginMeasure
            ))
        }
        commands.append(PaletteCommand(
            id: "passes",
            title: context.isPassesPanelOpen ? "Close satellite passes" : "Show satellite passes",
            subtitle: "Upcoming passes of the ISS and the selected satellite over the next two days",
            symbolName: "airplane.departure",
            category: .tool,
            aliases: ["passes", "iss pass", "flyover", "when is the iss", "satellite passes", "overhead"],
            action: .togglePassesPanel
        ))
        return commands
    }

    static func nightVisionCommand(context: PaletteContext) -> [PaletteCommand] {
        [
            PaletteCommand(
                id: "night-vision",
                title: context.isNightVisionEnabled
                    ? "Turn off night vision" : "Turn on night vision",
                subtitle: "Red-on-black, to keep your dark adaptation (N)",
                symbolName: "eye",
                category: .layer,
                aliases: ["night mode", "red mode", "dark adaptation", "toggle night mode"],
                action: .toggleNightVision
            )
        ]
    }

    static func panelCommands(context: PaletteContext) -> [PaletteCommand] {
        PalettePanel.allCases.map { panel in
            let isOpen = context.openPanels.contains(panel)
            return PaletteCommand(
                id: "panel-\(panel.rawValue)",
                // "…the Tonight panel", not "…Tonight": the bare word is also
                // a time destination ("Jump to tonight"), and a row whose title
                // is exactly the ambiguous word wins every query for it. Saying
                // "panel" is both clearer about what the row does and enough to
                // let the ranking put the time jump first, which is what a user
                // typing "tonight" almost always means.
                title: "\(isOpen ? "Close" : "Open") the \(panel.displayName) panel",
                subtitle: panel == .tonight
                    ? "Twilight, the Moon, and what is worth looking at"
                    : "Upcoming phases, seasons, oppositions and showers",
                symbolName: panel == .tonight ? "moon.stars" : "calendar",
                category: .layer,
                aliases: [panel.displayName, "show \(panel.displayName)"],
                action: .togglePanel(panel)
            )
        }
    }

    static func timeCommands() -> [PaletteCommand] {
        func command(
            _ id: String, _ title: String, _ subtitle: String, _ symbol: String,
            _ aliases: [String], _ action: PaletteTimeAction
        ) -> PaletteCommand {
            PaletteCommand(
                id: "time-\(id)", title: title, subtitle: subtitle, symbolName: symbol,
                category: .time, aliases: aliases, action: .time(action)
            )
        }
        return [
            command("now", "Back to now", "Real time, 1×", "clock.arrow.circlepath",
                    ["real time", "reset time", "today", "current time"], .now),
            // "tonight" is declared as an exact keyword here as well as on the
            // Tonight panel's row, deliberately: both commands genuinely own
            // the word, so both are scored on it at full weight and the
            // category weights decide between them — time above layers, which
            // is the ordering `PaletteCategory.weight` exists to express.
            command("tonight", "Jump to tonight", "The start of tonight's astronomical darkness",
                    "moon.stars", ["tonight", "dark", "darkness", "astronomical night"], .tonight),
            command("midnight", "Jump to midnight", "Midnight at the end of today, local time",
                    "moon", ["12am", "00:00"], .midnight),
            command("sunset", "Jump to sunset", "Today's sunset from here", "sunset",
                    ["dusk", "golden hour"], .sunset),
            command("sunrise", "Jump to sunrise", "Tomorrow morning's sunrise from here",
                    "sunrise", ["dawn"], .sunrise),
            command("play", "Play or pause time", "Freeze the sky where it is",
                    "playpause", ["pause", "freeze", "stop time", "resume"], .togglePlaying),
            command("day-forward", "Forward one day", "Same time tomorrow", "forward",
                    ["tomorrow", "next day", "+1 day"], .shiftDays(1)),
            command("day-back", "Back one day", "Same time yesterday", "backward",
                    ["yesterday", "previous day", "-1 day"], .shiftDays(-1)),
            command("hour-forward", "Forward one hour", "An hour later", "goforward",
                    ["+1 hour", "next hour"], .shiftHours(1)),
            command("hour-back", "Back one hour", "An hour earlier", "gobackward",
                    ["-1 hour", "previous hour"], .shiftHours(-1)),
            command("rate-fast", "Speed up to 60×", "A minute of sky a second", "hare",
                    ["fast forward", "speed"], .setRate(.fast)),
            command("rate-day", "Speed up to a day a second", "Watch the seasons turn",
                    "hare.fill", ["very fast", "days"], .setRate(.dayPerSecond)),
        ]
    }

    static func locationEntryCommand() -> [PaletteCommand] {
        [
            PaletteCommand(
                id: "location-entry",
                title: "Set location…",
                subtitle: "Type a place name and pick from the results",
                symbolName: "location",
                category: .location,
                aliases: ["change location", "move to", "observe from", "set location to", "where am i"],
                action: .beginLocationEntry
            )
        ]
    }

    static func eventCommands(context: PaletteContext) -> [PaletteCommand] {
        context.upcomingEvents.prefix(eventLimit).map { event in
            PaletteCommand(
                id: "event-\(event.id)",
                title: "Jump to \(event.title)",
                subtitle: DateFormatter.paletteEventDate.string(from: event.date),
                symbolName: event.kind.symbolName,
                category: .event,
                aliases: [event.title, "next \(event.title)", event.kind.displayName],
                action: .jumpToEvent(event)
            )
        }
    }

    static func objectCommands(context: PaletteContext) -> [PaletteCommand] {
        context.objectMatches.prefix(objectLimit).map { object in
            PaletteCommand(
                id: "object-\(object.id)",
                title: "Go to \(object.name)",
                subtitle: objectSubtitle(object),
                symbolName: symbolName(for: object.kind),
                category: .object,
                aliases: [object.name, object.catalogDesignation].compactMap { $0 },
                action: .focus(object)
            )
        }
    }

    static func locationCommands(context: PaletteContext) -> [PaletteCommand] {
        context.placeMatches.prefix(resultLimit).map { place in
            PaletteCommand(
                id: "place-\(place.name)-\(place.latitudeDegrees),\(place.longitudeDegrees)",
                title: place.name,
                subtitle: String(
                    format: "%.3f, %.3f", place.latitudeDegrees, place.longitudeDegrees
                ),
                symbolName: "mappin.and.ellipse",
                category: .location,
                aliases: [],
                action: .setLocation(
                    name: place.name,
                    latitudeDegrees: place.latitudeDegrees,
                    longitudeDegrees: place.longitudeDegrees
                )
            )
        }
    }

    // MARK: - Presentation helpers

    static func objectSubtitle(_ object: CelestialObject) -> String {
        var parts: [String] = [kindName(object.kind)]
        if let designation = object.catalogDesignation { parts.append(designation) }
        if object.kind != .constellation {
            parts.append("magnitude \(object.magnitude.formatted(.number.precision(.fractionLength(1))))")
        }
        return parts.joined(separator: " · ")
    }

    static func kindName(_ kind: CelestialObjectKind) -> String {
        switch kind {
        case .star: return "Star"
        case .sun: return "Sun"
        case .moon: return "Moon"
        case .planet: return "Planet"
        case .dwarfPlanet: return "Dwarf planet"
        case .deepSky: return "Deep sky"
        case .constellation: return "Constellation"
        case .planetMoon: return "Moon of Jupiter"
        case .satellite: return "Satellite"
        }
    }

    static func symbolName(for kind: CelestialObjectKind) -> String {
        switch kind {
        case .star: return "star"
        case .sun: return "sun.max"
        case .moon: return "moon"
        case .planet, .dwarfPlanet: return "circle.fill"
        case .deepSky: return "hurricane"
        case .constellation: return "line.diagonal"
        case .planetMoon: return "circle.dotted.circle"
        case .satellite: return "antenna.radiowaves.left.and.right"
        }
    }
}

extension DateFormatter {
    static let paletteEventDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM, HH:mm"
        return formatter
    }()
}
