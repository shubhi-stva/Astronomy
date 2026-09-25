//
//  CommandPaletteTests.swift
//  AstronomyTests
//
//  The palette's whole risk is that a query produces the wrong command, or the
//  right command in the wrong place in the list. Both are properties of pure
//  functions here — `FuzzyMatch.score` and `CommandProvider.commands` — which
//  is exactly why the action is a value rather than a closure.
//

import XCTest
@testable import Astronomy

// MARK: - Matching

final class FuzzyMatchTests: XCTestCase {

    func testAnEmptyQueryMatchesEverything() {
        XCTAssertEqual(FuzzyMatch.score(query: "", candidate: "Show grid"), 0)
    }

    func testANonSubsequenceDoesNotMatch() {
        XCTAssertNil(FuzzyMatch.score(query: "zzz", candidate: "Go to Jupiter"))
        XCTAssertNil(FuzzyMatch.score(query: "retipuj", candidate: "Go to Jupiter"))
    }

    func testMatchingIsCaseAndSpaceInsensitive() {
        XCTAssertNotNil(FuzzyMatch.score(query: "GO TO", candidate: "Go to Jupiter"))
        XCTAssertNotNil(FuzzyMatch.score(query: "g o t o", candidate: "Go to Jupiter"))
    }

    func testAPrefixBeatsAMatchInTheMiddle() {
        let prefix = FuzzyMatch.score(query: "jup", candidate: "Jupiter")!
        let middle = FuzzyMatch.score(query: "jup", candidate: "Go to Jupiter")!
        XCTAssertGreaterThan(prefix, middle)
    }

    func testInitialsWork() {
        XCTAssertNotNil(FuzzyMatch.score(query: "gtj", candidate: "Go to Jupiter"))
        let initials = FuzzyMatch.score(query: "sg", candidate: "Show grid")!
        let scattered = FuzzyMatch.score(query: "sg", candidate: "Satellites are big")!
        XCTAssertGreaterThan(initials, scattered)
    }

    /// Synthetic candidates, so neither gets a leading or word-start bonus and
    /// the only difference measured is contiguity.
    func testAdjacentCharactersBeatScatteredOnes() {
        let adjacent = FuzzyMatch.score(query: "grid", candidate: "xxgridxx")!
        let scattered = FuzzyMatch.score(query: "grid", candidate: "xgxrxixd")!
        XCTAssertGreaterThan(adjacent, scattered)
    }

    /// The specific failure a pure subsequence scorer has: "tonight" is
    /// scattered through "Turn on night vision" and must not beat the row where
    /// it is the actual word.
    func testAnExactWordBeatsAScatteredSubsequenceOfIt() {
        let word = FuzzyMatch.score(query: "tonight", candidate: "Jump to tonight")!
        let scattered = FuzzyMatch.score(query: "tonight", candidate: "Turn on night vision")!
        XCTAssertGreaterThan(word, scattered)
    }

    func testShorterCandidatesWinTies() {
        let short = FuzzyMatch.score(query: "mars", candidate: "Mars")!
        let long = FuzzyMatch.score(query: "mars", candidate: "Mars and everything near it")!
        XCTAssertGreaterThan(short, long)
    }

    /// A *partial* hit on a hidden keyword is discounted...
    func testPartialAliasHitsAreScoredAtADiscount() {
        let direct = FuzzyMatch.bestScore(query: "grid", title: "grid lines", aliases: [])!
        let viaAlias = FuzzyMatch.bestScore(
            query: "grid", title: "nothing here", aliases: ["grid lines"]
        )
        XCTAssertNotNil(viaAlias)
        XCTAssertLessThan(viaAlias!, direct)
    }

    /// ...but a query that *is* the keyword is not, because that is the
    /// strongest signal of intent there is. Without this, a command declaring
    /// "grid" lost the query "grid" to any command with a shorter title that
    /// merely contained the word — which is exactly what happened when a second
    /// grid layer arrived.
    func testAnExactAliasHitIsNotDiscounted() {
        let direct = FuzzyMatch.bestScore(query: "grid", title: "grid", aliases: [])!
        let viaAlias = FuzzyMatch.bestScore(query: "grid", title: "nothing here", aliases: ["grid"])
        XCTAssertEqual(viaAlias!, direct, accuracy: 1e-9)

        // Case and spacing do not change what "the same word" means.
        XCTAssertEqual(
            FuzzyMatch.bestScore(query: "Deep Sky", title: "zzz", aliases: ["deepsky"])!,
            FuzzyMatch.bestScore(query: "deepsky", title: "deepsky", aliases: [])!,
            accuracy: 1e-9
        )
    }

    func testAQueryLongerThanTheCandidateCannotMatch() {
        XCTAssertNil(FuzzyMatch.score(query: "jupiterjupiter", candidate: "Jupiter"))
    }
}

// MARK: - Provider

final class CommandProviderTests: XCTestCase {

    private func context() -> PaletteContext {
        var context = PaletteContext()
        context.layers = [
            .constellationLines: true,
            .deepSky: true,
            .equatorialGrid: false,
            .satellites: true,
            .allSatellites: false,
        ]
        return context
    }

    private func topAction(_ query: String, _ context: PaletteContext) -> PaletteAction? {
        CommandProvider.commands(query: query, context: context).first?.action
    }

    // MARK: Layer commands

    func testShowGridFindsTheGrid() {
        XCTAssertEqual(topAction("show grid", context()), .toggleLayer(.equatorialGrid))
        XCTAssertEqual(topAction("grid", context()), .toggleLayer(.equatorialGrid))
    }

    func testHideConstellationLinesFindsTheLines() {
        XCTAssertEqual(
            topAction("hide constellation lines", context()),
            .toggleLayer(.constellationLines)
        )
    }

    /// The title states what choosing the row will do, so it has to follow the
    /// layer's current state rather than being fixed.
    func testTheLayerTitleFollowsTheCurrentState() {
        var on = context()
        on.layers[.equatorialGrid] = true
        let shown = CommandProvider.commands(query: "grid", context: on).first!
        XCTAssertTrue(shown.title.hasPrefix("Hide"))

        let hidden = CommandProvider.commands(query: "grid", context: context()).first!
        XCTAssertTrue(hidden.title.hasPrefix("Show"))
    }

    /// ...but both verbs must still find the row, or the command is unreachable
    /// half the time.
    func testBothVerbsFindTheRowWhicheverWayItReads() {
        var on = context()
        on.layers[.equatorialGrid] = true
        XCTAssertEqual(topAction("show grid", on), .toggleLayer(.equatorialGrid))
        XCTAssertEqual(topAction("hide grid", on), .toggleLayer(.equatorialGrid))
    }

    func testEveryLayerIsReachable() {
        for layer in SkyLayer.allCases {
            let matches = CommandProvider.commands(query: layer.displayName, context: context())
            XCTAssertTrue(
                matches.contains { $0.action == .toggleLayer(layer) },
                "\(layer.rawValue) is not reachable by its own name"
            )
        }
    }

    // MARK: Night vision

    func testNightModeIsReachable() {
        XCTAssertEqual(topAction("night mode", context()), .toggleNightVision)
        XCTAssertEqual(topAction("night vision", context()), .toggleNightVision)
    }

    // MARK: Time commands

    func testTimeCommandsDispatch() {
        XCTAssertEqual(topAction("jump to midnight", context()), .time(.midnight))
        XCTAssertEqual(topAction("tonight", context()), .time(.tonight))
        XCTAssertEqual(topAction("sunset", context()), .time(.sunset))
        XCTAssertEqual(topAction("back to now", context()), .time(.now))
    }

    // MARK: Objects

    func testGoToJupiterFindsJupiter() {
        var context = context()
        context.objectMatches = [
            CelestialObject(
                id: "jupiter", name: "Jupiter", kind: .planet,
                equatorial: EquatorialCoordinate(
                    rightAscensionDegrees: 60, declinationDegrees: 20
                ),
                magnitude: -2.2
            )
        ]
        guard case .focus(let object)? = topAction("jupiter", context) else {
            return XCTFail("expected a focus action, got \(String(describing: topAction("jupiter", context)))")
        }
        XCTAssertEqual(object.id, "jupiter")
    }

    func testShowOrionFindsTheConstellation() {
        var context = context()
        context.objectMatches = [
            CelestialObject(
                id: "constellation-Orion", name: "Orion", kind: .constellation,
                equatorial: EquatorialCoordinate(
                    rightAscensionDegrees: 83, declinationDegrees: 2
                ),
                magnitude: 0
            )
        ]
        guard case .focus(let object)? = topAction("orion", context) else {
            return XCTFail("expected a focus action")
        }
        XCTAssertEqual(object.name, "Orion")
    }

    /// The palette must not turn into a second, worse search bar: only a
    /// handful of object rows, however many the index returned.
    func testObjectMatchesAreCapped() {
        var context = context()
        context.objectMatches = (0..<50).map { index in
            CelestialObject(
                id: "star-\(index)", name: "Alpha \(index)", kind: .star,
                equatorial: EquatorialCoordinate(
                    rightAscensionDegrees: 10, declinationDegrees: 10
                ),
                magnitude: 3
            )
        }
        let objects = CommandProvider.commands(query: "alpha", context: context)
            .filter { $0.category == .object }
        XCTAssertLessThanOrEqual(objects.count, CommandProvider.objectLimit)
    }

    /// An action and an object that match equally well: the action wins,
    /// because the search bar already exists for finding things.
    func testAnActionOutranksAnObjectOnAnEqualMatch() {
        var context = context()
        context.objectMatches = [
            CelestialObject(
                id: "grid-star", name: "Grid", kind: .star,
                equatorial: EquatorialCoordinate(
                    rightAscensionDegrees: 1, declinationDegrees: 1
                ),
                magnitude: 5
            )
        ]
        XCTAssertEqual(topAction("grid", context), .toggleLayer(.equatorialGrid))
    }

    /// ...but a decisively better textual match still wins, or the weighting
    /// would have made objects unreachable.
    func testAStrongObjectMatchStillWins() {
        var context = context()
        context.objectMatches = [
            CelestialObject(
                id: "betelgeuse", name: "Betelgeuse", kind: .star,
                equatorial: EquatorialCoordinate(
                    rightAscensionDegrees: 88, declinationDegrees: 7
                ),
                magnitude: 0.5
            )
        ]
        guard case .focus? = topAction("betelgeuse", context) else {
            return XCTFail("a full star name should outrank every action")
        }
    }

    // MARK: Events

    func testCalendarEventsAreOfferedAndDispatch() {
        var context = context()
        let event = MoonPhaseEvents.event(phase: .fullMoon, julianDay: 2_461_000.5)
        context.upcomingEvents = [event]
        guard case .jumpToEvent(let jumped)? = topAction("full moon", context) else {
            return XCTFail("expected a jump action")
        }
        XCTAssertEqual(jumped.id, event.id)
    }

    // MARK: Location

    func testSetLocationEntersLocationMode() {
        XCTAssertEqual(topAction("set location to", context()), .beginLocationEntry)
    }

    /// In location mode the query is a place name, so nothing else may appear:
    /// a user typing "Tokyo" must not be offered "Toggle satellites".
    func testLocationModeShowsOnlyPlaces() {
        var context = context()
        context.isLocationMode = true
        context.placeMatches = [
            PaletteContext.Place(
                name: "Tokyo, Tokyo", latitudeDegrees: 35.68, longitudeDegrees: 139.69
            )
        ]
        let commands = CommandProvider.commands(query: "tokyo", context: context)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(
            commands[0].action,
            .setLocation(name: "Tokyo, Tokyo", latitudeDegrees: 35.68, longitudeDegrees: 139.69)
        )
    }

    func testLocationModeWithNoResultsIsEmptyRatherThanFallingBack() {
        var context = context()
        context.isLocationMode = true
        XCTAssertTrue(CommandProvider.commands(query: "tokyo", context: context).isEmpty)
    }

    // MARK: List shape

    /// An empty query is the "what can this do" case, so it shows actions —
    /// never objects, of which there are none yet anyway.
    func testAnEmptyQueryShowsActionsOnly() {
        let commands = CommandProvider.commands(query: "", context: context())
        XCTAssertFalse(commands.isEmpty)
        XCTAssertFalse(commands.contains { $0.category == .object })
        XCTAssertLessThanOrEqual(commands.count, CommandProvider.resultLimit)
    }

    func testTheListIsCappedAndUniquelyIdentified() {
        var context = context()
        context.objectMatches = (0..<50).map { index in
            CelestialObject(
                id: "star-\(index)", name: "Star \(index)", kind: .star,
                equatorial: EquatorialCoordinate(
                    rightAscensionDegrees: 1, declinationDegrees: 1
                ),
                magnitude: 3
            )
        }
        let commands = CommandProvider.commands(query: "s", context: context)
        XCTAssertLessThanOrEqual(commands.count, CommandProvider.resultLimit)
        XCTAssertEqual(Set(commands.map(\.id)).count, commands.count)
    }

    func testResultsAreSortedByScoreDescending() {
        let commands = CommandProvider.commands(query: "sh", context: context())
        for (a, b) in zip(commands, commands.dropFirst()) {
            XCTAssertGreaterThanOrEqual(a.score, b.score)
        }
    }

    func testNothingMatchesNonsense() {
        XCTAssertTrue(
            CommandProvider.commands(query: "qqzzxx", context: context()).isEmpty
        )
    }

    /// Every command carries a title and a symbol, so no row can render blank.
    func testEveryCommandIsPresentable() {
        for command in CommandProvider.allCandidates(context: context()) {
            XCTAssertFalse(command.title.isEmpty, "\(command.id) has no title")
            XCTAssertFalse(command.symbolName.isEmpty, "\(command.id) has no symbol")
        }
    }
}
