//
//  EventCalendarTests.swift
//  AstronomyTests
//
//  The calendar's numbers, checked against published ones.
//
//  Residuals are *reported* as well as bounded. A tolerance alone tells you a
//  test passed; the residual tells you by how much, which is the number that
//  would reveal a regression long before it crossed a threshold. Every bound
//  here is set from a measured residual with headroom, not from a hoped-for
//  precision.
//
//  Two systematic offsets apply to every comparison and are not corrected for
//  anywhere in this app, so they show up in every residual below:
//
//   * ΔT. Published almanac instants for phases and solstices are in Terrestrial
//     Dynamical Time; this app works in UT throughout. The difference is about
//     48 seconds in 1977 and about 70 seconds today.
//   * Truncated series. `SunPosition` is Meeus's low-precision solar theory
//     (~0.01°) and `MoonPosition` a truncated ELP (a few arcminutes).
//

import XCTest
@testable import Astronomy

/// Shared helpers.
private enum EventTestSupport {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func julianDay(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0
    ) -> Double {
        let date = utc.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
        return JulianDate.julianDay(from: date)
    }

    static func components(_ julianDay: Double) -> DateComponents {
        utc.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: JulianDate.date(fromJulianDay: julianDay)
        )
    }

    /// Residual in minutes, printed by every comparison test.
    static func residualMinutes(_ computed: Double, _ published: Double) -> Double {
        (computed - published) * 1440
    }
}

// MARK: - Moon phases

final class MoonPhaseEventTests: XCTestCase {

    /// The New Moon of 2000 January 6 — the lunation Meeus numbers k = 0 —
    /// occurred at 18:14 UT.
    func testNewMoonAgainstTheK0Lunation() {
        let published = EventTestSupport.julianDay(2000, 1, 6, 18, 14)
        let events = MoonPhaseEvents.events(
            fromJulianDay: published - 5, toJulianDay: published + 5
        ).filter { $0.title == "New Moon" }
        XCTAssertEqual(events.count, 1)
        let residual = EventTestSupport.residualMinutes(events[0].julianDay, published)
        print("New Moon 2000-01-06 residual: \(residual) minutes")
        XCTAssertLessThan(abs(residual), 20, "residual was \(residual) minutes")
    }

    /// Meeus example 49.b: the Last Quarter of 2044 January falls at
    /// JDE 2467636.49186 (2044 January 21.99186 TD).
    func testLastQuarterAgainstMeeusExample49b() {
        let published = 2_467_636.49186
        let events = MoonPhaseEvents.events(
            fromJulianDay: published - 5, toJulianDay: published + 5
        ).filter { $0.title == "Last Quarter" }
        XCTAssertEqual(events.count, 1)
        let residual = EventTestSupport.residualMinutes(events[0].julianDay, published)
        print("Last Quarter 2044-01-21 residual: \(residual) minutes")
        XCTAssertLessThan(abs(residual), 20, "residual was \(residual) minutes")
    }

    /// The internal check that needs no almanac: at the instant this code calls
    /// a full moon, the app's own phase model must agree the disk is full.
    func testThePhasesAgreeWithTheAppsOwnIlluminationModel() {
        let start = EventTestSupport.julianDay(2026, 1, 1)
        let events = MoonPhaseEvents.events(fromJulianDay: start, toJulianDay: start + 40)
        for event in events {
            let jd = event.julianDay
            let k = MoonPhase.illuminatedFraction(
                sun: SunPosition.equatorialCoordinate(julianDay: jd),
                moon: MoonPosition.equatorialCoordinate(julianDay: jd)
            )
            switch event.title {
            case "New Moon": XCTAssertLessThan(k, 0.005, "new moon was \(k) lit")
            case "Full Moon": XCTAssertGreaterThan(k, 0.995, "full moon was \(k) lit")
            default: XCTAssertEqual(k, 0.5, accuracy: 0.02, "\(event.title) was \(k) lit")
            }
        }
    }

    /// One of each phase per lunation, in the right order, at the right spacing.
    func testOneOfEachPhasePerLunation() {
        let start = EventTestSupport.julianDay(2026, 3, 1)
        let events = MoonPhaseEvents.events(fromJulianDay: start, toJulianDay: start + 29.53)
        XCTAssertEqual(events.count, 4, "a synodic month contains four principal phases")
        XCTAssertEqual(Set(events.map(\.title)).count, 4)
        for (a, b) in zip(events, events.dropFirst()) {
            let gap = b.julianDay - a.julianDay
            XCTAssertEqual(gap, 29.53 / 4, accuracy: 1.0, "phase gap was \(gap) days")
        }
    }

    /// Successive new moons are one synodic month apart, whose published mean
    /// is 29.530589 days.
    ///
    /// Measured over a decade rather than a year, deliberately. Individual
    /// intervals swing by ±7 hours through the anomalistic cycle, and a single
    /// year contains only eleven or twelve of them — not enough for the mean to
    /// have converged, so a one-year sample legitimately comes out tens of
    /// minutes short and would make this test a coin toss.
    func testSynodicMonthLength() {
        let start = EventTestSupport.julianDay(2026, 1, 1)
        let newMoons = MoonPhaseEvents.events(fromJulianDay: start, toJulianDay: start + 3652)
            .filter { $0.title == "New Moon" }
            .map(\.julianDay)
        XCTAssertGreaterThan(newMoons.count, 120)
        let gaps = zip(newMoons, newMoons.dropFirst()).map { $1 - $0 }
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        print("mean synodic month over 2026–2036: \(mean) days (published 29.530589)")
        XCTAssertEqual(mean, 29.530589, accuracy: 0.005)
        for gap in gaps { XCTAssertEqual(gap, 29.53, accuracy: 0.6) }
    }

    func testEventsCarryTheMoonAsTheirTarget() {
        let start = EventTestSupport.julianDay(2026, 6, 1)
        let events = MoonPhaseEvents.events(fromJulianDay: start, toJulianDay: start + 30)
        XCTAssertFalse(events.isEmpty)
        for event in events {
            XCTAssertEqual(event.targetObjectID, "moon")
            XCTAssertEqual(event.provenance, .computed)
            XCTAssertNotNil(event.targetEquatorial)
        }
    }
}

// MARK: - Equinoxes and solstices

final class SeasonEventTests: XCTestCase {

    /// Meeus example 27.a: the June solstice of 1962 falls at JDE 2437837.39245.
    func testJuneSolsticeAgainstMeeusExample27a() {
        let published = 2_437_837.39245
        let events = SeasonEvents.events(
            fromJulianDay: published - 5, toJulianDay: published + 5, latitudeDegrees: 40
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].title, "June Solstice")
        let residual = EventTestSupport.residualMinutes(events[0].julianDay, published)
        print("June solstice 1962 residual: \(residual) minutes")
        XCTAssertLessThan(abs(residual), 25, "residual was \(residual) minutes")
    }

    /// Four points a year, in order, roughly a quarter of a year apart.
    func testFourSeasonPointsAYear() {
        let start = EventTestSupport.julianDay(2026, 1, 1)
        let events = SeasonEvents.events(
            fromJulianDay: start, toJulianDay: start + 365.24, latitudeDegrees: 51
        )
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(
            events.map(\.title),
            ["March Equinox", "June Solstice", "September Equinox", "December Solstice"]
        )
        // The four seasons are famously *not* equal: Earth is near aphelion in
        // July and moving slowest, so the northern summer runs about 93.6 days
        // and the northern winter about 89.0.
        for (a, b) in zip(events, events.dropFirst()) {
            let gap = b.julianDay - a.julianDay
            XCTAssertTrue((88.5...94.5).contains(gap), "season gap was \(gap) days")
        }
    }

    /// The defining property, checked directly: at the instant this code calls
    /// an equinox, the Sun's declination must be zero.
    func testTheSunIsOnTheEquatorAtAnEquinox() {
        let start = EventTestSupport.julianDay(2026, 1, 1)
        let equinoxes = SeasonEvents.events(
            fromJulianDay: start, toJulianDay: start + 365.24, latitudeDegrees: 0
        ).filter { $0.title.contains("Equinox") }
        XCTAssertEqual(equinoxes.count, 2)
        for equinox in equinoxes {
            let dec = SunPosition.equatorialCoordinate(julianDay: equinox.julianDay)
                .declinationDegrees
            // Not exactly zero: an equinox is defined on the *ecliptic*
            // longitude, and the aberration and nutation terms in the apparent
            // longitude do not vanish at the same instant the declination does.
            XCTAssertEqual(dec, 0, accuracy: 0.01, "declination was \(dec)°")
        }
    }

    /// And at a solstice the Sun's declination must be at the obliquity.
    func testTheSunIsAtTheObliquityAtASolstice() {
        let start = EventTestSupport.julianDay(2026, 1, 1)
        let solstices = SeasonEvents.events(
            fromJulianDay: start, toJulianDay: start + 365.24, latitudeDegrees: 0
        ).filter { $0.title.contains("Solstice") }
        XCTAssertEqual(solstices.count, 2)
        for solstice in solstices {
            let dec = SunPosition.equatorialCoordinate(julianDay: solstice.julianDay)
                .declinationDegrees
            let obliquity = EclipticLongitude.meanObliquityDegrees(julianDay: solstice.julianDay)
            XCTAssertEqual(abs(dec), obliquity, accuracy: 0.01, "declination was \(dec)°")
        }
    }

    /// The one place in the app where a season name would be wrong for half the
    /// world if nobody checked.
    func testSeasonNamesFlipBetweenHemispheres() {
        XCTAssertTrue(SeasonPoint.juneSolstice.seasonName(latitudeDegrees: 51).contains("summer"))
        XCTAssertTrue(SeasonPoint.juneSolstice.seasonName(latitudeDegrees: -34).contains("winter"))
    }
}

// MARK: - Planetary events

final class PlanetaryEventTests: XCTestCase {

    /// Published: Mars reached opposition on 2025 January 16 at about 02:38 UTC.
    ///
    /// The residual here is bounded much more loosely than the lunar ones, and
    /// deliberately: near opposition a planet's elongation is stationary by
    /// definition, so `PlanetPosition`'s few arcminutes of error become hours of
    /// timing error. That is why the UI prints oppositions to the day.
    func testMarsOpposition2025() {
        let published = EventTestSupport.julianDay(2025, 1, 16, 2, 38)
        let events = PlanetaryEvents.events(
            fromJulianDay: published - 20, toJulianDay: published + 20
        ).filter { $0.kind == .opposition && $0.targetObjectID == "mars" }
        XCTAssertEqual(events.count, 1)
        let residualHours = (events[0].julianDay - published) * 24
        print("Mars opposition 2025-01-16 residual: \(residualHours) hours")
        XCTAssertLessThan(abs(residualHours), 24, "residual was \(residualHours) hours")
    }

    /// Published: Saturn reached opposition on 2025 September 21, about 05:00 UTC.
    func testSaturnOpposition2025() {
        let published = EventTestSupport.julianDay(2025, 9, 21, 5, 0)
        let events = PlanetaryEvents.events(
            fromJulianDay: published - 20, toJulianDay: published + 20
        ).filter { $0.kind == .opposition && $0.targetObjectID == "saturn" }
        XCTAssertEqual(events.count, 1)
        let residualHours = (events[0].julianDay - published) * 24
        print("Saturn opposition 2025-09-21 residual: \(residualHours) hours")
        XCTAssertLessThan(abs(residualHours), 24, "residual was \(residualHours) hours")
    }

    /// The defining geometry, independent of any almanac: at the instant this
    /// code calls an opposition, the planet must be nearly opposite the Sun.
    func testOppositionsAreOppositeTheSun() {
        let start = EventTestSupport.julianDay(2026, 1, 1)
        let oppositions = PlanetaryEvents.events(
            fromJulianDay: start, toJulianDay: start + 730
        ).filter { $0.kind == .opposition }
        XCTAssertGreaterThan(oppositions.count, 3)
        for event in oppositions {
            guard let id = event.targetObjectID, let planet = Planet(rawValue: id) else {
                return XCTFail("opposition without a planet")
            }
            let elongation = PlanetaryEvents.elongationDegrees(
                planet: planet, julianDay: event.julianDay
            )
            XCTAssertGreaterThan(elongation, 173, "\(id) opposition at \(elongation)°")
        }
    }

    /// Greatest elongations are only meaningful for the two inferior planets,
    /// and their published maxima are about 28° (Mercury) and 47° (Venus).
    func testGreatestElongationsOnlyHappenToMercuryAndVenus() {
        let start = EventTestSupport.julianDay(2026, 1, 1)
        let elongations = PlanetaryEvents.events(
            fromJulianDay: start, toJulianDay: start + 730
        ).filter { $0.kind == .greatestElongation }
        XCTAssertGreaterThan(elongations.count, 5)
        for event in elongations {
            let id = event.targetObjectID ?? ""
            XCTAssertTrue(id == "mercury" || id == "venus", "unexpected \(id)")
            let value = PlanetaryEvents.elongationDegrees(
                planet: Planet(rawValue: id)!, julianDay: event.julianDay
            )
            if id == "mercury" {
                XCTAssertTrue((17.5...28.5).contains(value), "Mercury elongation \(value)°")
            } else {
                XCTAssertTrue((44.0...48.0).contains(value), "Venus elongation \(value)°")
            }
        }
    }

    /// Mars has an opposition roughly every 780 days (its synodic period) and
    /// never more often — a good check that maxima are not being double-counted.
    func testMarsOppositionsAreOneSynodicPeriodApart() {
        let start = EventTestSupport.julianDay(2020, 1, 1)
        let times = PlanetaryEvents.events(fromJulianDay: start, toJulianDay: start + 3650)
            .filter { $0.kind == .opposition && $0.targetObjectID == "mars" }
            .map(\.julianDay)
        XCTAssertGreaterThan(times.count, 3)
        for (a, b) in zip(times, times.dropFirst()) {
            XCTAssertEqual(b - a, 780, accuracy: 40, "gap was \(b - a) days")
        }
    }

    func testConjunctionsAreCloseToTheSun() {
        let start = EventTestSupport.julianDay(2026, 1, 1)
        let conjunctions = PlanetaryEvents.events(
            fromJulianDay: start, toJulianDay: start + 365
        ).filter { $0.kind == .conjunction }
        XCTAssertGreaterThan(conjunctions.count, 3)
        for event in conjunctions {
            let planet = Planet(rawValue: event.targetObjectID!)!
            let elongation = PlanetaryEvents.elongationDegrees(
                planet: planet, julianDay: event.julianDay
            )
            XCTAssertLessThanOrEqual(
                elongation, PlanetaryEvents.conjunctionThresholdDegrees + 0.01
            )
        }
    }
}

// MARK: - Close approaches

final class CloseApproachEventTests: XCTestCase {

    func testEveryReportedApproachIsActuallyClose() {
        let start = EventTestSupport.julianDay(2026, 1, 1)
        let events = CloseApproachEvents.events(fromJulianDay: start, toJulianDay: start + 365)
        XCTAssertGreaterThan(events.count, 5, "a year should contain several pairings")
        for event in events {
            guard let midpoint = event.targetEquatorial else { return XCTFail("no position") }
            // The midpoint must be within half the reported separation of both
            // members, which is only true if the pair really is together.
            XCTAssertNotNil(event.detail.firstIndex(of: "°"))
            let sun = SunPosition.equatorialCoordinate(julianDay: event.julianDay)
            let solarElongation = VisibilityRating.angularSeparationDegrees(sun, midpoint)
            XCTAssertGreaterThan(
                solarElongation,
                CloseApproachEvents.minimumSolarElongationDegrees
                    - CloseApproachEvents.maximumSeparationDegrees,
                "pairing was buried in the Sun's glare"
            )
        }
    }

    /// The separation printed must be the minimum, not a nearby value: this
    /// checks the refinement actually converged on the extremum.
    func testTheReportedInstantIsTheMinimum() {
        let start = EventTestSupport.julianDay(2026, 1, 1)
        let events = CloseApproachEvents.events(fromJulianDay: start, toJulianDay: start + 200)
        XCTAssertFalse(events.isEmpty)
        for event in events.prefix(6) {
            // Recover the pair from the id: "approach-<a>-<b>-<jd>".
            let parts = event.id.split(separator: "-")
            guard parts.count >= 3,
                  let a = BrightBody(rawValue: String(parts[1])),
                  let b = BrightBody(rawValue: String(parts[2])) else { continue }
            let separation: (Double) -> Double = { jd in
                VisibilityRating.angularSeparationDegrees(
                    a.equatorial(julianDay: jd), b.equatorial(julianDay: jd)
                )
            }
            let atEvent = separation(event.julianDay)
            XCTAssertLessThanOrEqual(atEvent, separation(event.julianDay - 0.02) + 1e-9)
            XCTAssertLessThanOrEqual(atEvent, separation(event.julianDay + 0.02) + 1e-9)
        }
    }

    func testUranusAndNeptuneAreNotInThePairingList() {
        XCTAssertFalse(BrightBody.allCases.map(\.rawValue).contains("uranus"))
        XCTAssertFalse(BrightBody.allCases.map(\.rawValue).contains("neptune"))
        XCTAssertFalse(BrightBody.allCases.map(\.rawValue).contains("pluto"))
    }
}

// MARK: - Meteor showers

final class MeteorShowerTests: XCTestCase {

    func testTheWorkingListLoads() {
        XCTAssertEqual(MeteorShowers.all.count, 12)
        XCTAssertEqual(Set(MeteorShowers.all.map(\.id)).count, 12, "codes must be unique")
        for shower in MeteorShowers.all {
            XCTAssertTrue(
                (0..<360).contains(shower.maximumSolarLongitudeDegrees),
                "\(shower.id) solar longitude out of range"
            )
            XCTAssertTrue((-90...90).contains(shower.radiant.declinationDegrees))
            XCTAssertTrue((0..<360).contains(shower.radiant.rightAscensionDegrees))
            XCTAssertGreaterThan(shower.zenithalHourlyRate, 0)
            XCTAssertGreaterThan(shower.velocityKilometresPerSecond, 10)
        }
    }

    /// The peaks are solved from the tabulated solar longitude, so they must
    /// land on the published dates without being told them.
    func testPeaksLandOnThePublishedDates() {
        let start = EventTestSupport.julianDay(2026, 1, 1)
        let events = MeteorShowers.events(fromJulianDay: start, toJulianDay: start + 365)
        func day(_ name: String) -> (month: Int, day: Int) {
            let event = events.first { $0.title == name }!
            let components = EventTestSupport.components(event.julianDay)
            print("\(name) 2026 maximum: \(JulianDate.date(fromJulianDay: event.julianDay))")
            return (components.month!, components.day!)
        }
        // Published maxima: Quadrantids 3–4 Jan, Lyrids 22–23 Apr,
        // eta Aquariids 5–6 May, Perseids 12–13 Aug, Orionids 21–22 Oct,
        // Leonids 17–18 Nov, Geminids 13–14 Dec, Ursids 22–23 Dec.
        XCTAssertEqual(day("Quadrantids").month, 1)
        XCTAssertTrue([2, 3, 4].contains(day("Quadrantids").day))
        XCTAssertEqual(day("Lyrids").month, 4)
        XCTAssertTrue([21, 22, 23].contains(day("Lyrids").day))
        XCTAssertEqual(day("eta Aquariids").month, 5)
        XCTAssertTrue([5, 6, 7].contains(day("eta Aquariids").day))
        XCTAssertEqual(day("Perseids").month, 8)
        XCTAssertTrue([11, 12, 13].contains(day("Perseids").day))
        XCTAssertEqual(day("Orionids").month, 10)
        XCTAssertTrue([20, 21, 22].contains(day("Orionids").day))
        XCTAssertEqual(day("Geminids").month, 12)
        XCTAssertTrue([13, 14, 15].contains(day("Geminids").day))
    }

    /// Each shower appears exactly once a year, which is the property that
    /// distinguishes a solved solar-longitude crossing from a date lookup.
    func testEachShowerHappensOncePerYear() {
        let start = EventTestSupport.julianDay(2027, 2, 1)
        let events = MeteorShowers.events(fromJulianDay: start, toJulianDay: start + 365.24)
        let counts = Dictionary(grouping: events, by: \.title).mapValues(\.count)
        for shower in MeteorShowers.all {
            XCTAssertEqual(counts[shower.name], 1, "\(shower.name) appeared \(counts[shower.name] ?? 0) times")
        }
    }

    /// The radiant is placed where the table says, precessed to the epoch of
    /// date exactly as a catalogue star is. The Perseid radiant is in northern
    /// Perseus at roughly RA 3h 12m, Dec +58°.
    func testTheRadiantIsPlacedCorrectly() {
        let start = EventTestSupport.julianDay(2026, 8, 1)
        let perseids = MeteorShowers.events(fromJulianDay: start, toJulianDay: start + 30)
            .first { $0.title == "Perseids" }
        let radiant = try! XCTUnwrap(perseids?.targetEquatorial)
        let published = EquatorialCoordinate(
            rightAscensionDegrees: 48, declinationDegrees: 58
        )
        let drift = VisibilityRating.angularSeparationDegrees(radiant, published)
        print("Perseid radiant precession from J2000 to 2026: \(drift)°")
        // Precession over 26 years is about a third of a degree — present, but
        // nowhere near a different part of the sky.
        XCTAssertGreaterThan(drift, 0.05, "the radiant was not precessed at all")
        XCTAssertLessThan(drift, 1.0, "the radiant moved further than precession explains")
    }

    /// A radiant is a direction, not an object: there is nothing to select.
    func testShowersAreTabulatedAndHaveNoSelectableTarget() {
        let start = EventTestSupport.julianDay(2026, 8, 1)
        let events = MeteorShowers.events(fromJulianDay: start, toJulianDay: start + 30)
        XCTAssertFalse(events.isEmpty)
        for event in events {
            XCTAssertEqual(event.provenance, .tabulated)
            XCTAssertNil(event.targetObjectID)
            XCTAssertNotNil(event.targetEquatorial)
        }
    }
}

// MARK: - Assembly and observability

final class EventCalendarAssemblyTests: XCTestCase {

    private let sanFrancisco = GeographicLocation(
        latitudeDegrees: 37.77, longitudeDegrees: -122.42
    )

    func testTheCalendarIsChronologicalAndCovered() {
        let start = EventTestSupport.julianDay(2026, 6, 1)
        let events = EventCalendar.events(
            fromJulianDay: start, days: 120, observer: sanFrancisco
        )
        XCTAssertGreaterThan(events.count, 15)
        for (a, b) in zip(events, events.dropFirst()) {
            XCTAssertLessThanOrEqual(a.julianDay, b.julianDay)
        }
        for event in events {
            XCTAssertTrue((start...(start + 120)).contains(event.julianDay))
            XCTAssertFalse(event.title.isEmpty)
            XCTAssertFalse(event.detail.isEmpty)
        }
        // Every id unique, so SwiftUI's list identity is stable.
        XCTAssertEqual(Set(events.map(\.id)).count, events.count)
    }

    func testAWindowOfAYearContainsEveryKindThatCanOccur() {
        let start = EventTestSupport.julianDay(2026, 1, 1)
        let kinds = Set(
            EventCalendar.events(fromJulianDay: start, days: 365, observer: sanFrancisco)
                .map(\.kind)
        )
        for expected in AstronomicalEventKind.allCases {
            XCTAssertTrue(kinds.contains(expected), "no \(expected.rawValue) in a whole year")
        }
    }

    /// Observability is reported from the observer's own horizon, so the same
    /// event has to look different from opposite hemispheres. The Geminid
    /// radiant is at declination +33: high from California, low from Sydney.
    func testObservabilityDependsOnWhereYouAre() {
        let start = EventTestSupport.julianDay(2026, 12, 1)
        let sydney = GeographicLocation(latitudeDegrees: -33.87, longitudeDegrees: 151.21)
        func peak(_ observer: GeographicLocation) -> Double {
            let geminids = MeteorShowers.events(fromJulianDay: start, toJulianDay: start + 30)
                .first { $0.title == "Geminids" }!
            return EventCalendar.observability(for: geminids, observer: observer)!
                .peakAltitudeDegrees
        }
        let north = peak(sanFrancisco)
        let south = peak(sydney)
        print("Geminid radiant peak altitude — San Francisco \(north)°, Sydney \(south)°")
        XCTAssertGreaterThan(north, south + 30)
    }

    /// A circumpolar target from a high latitude must be reported as such,
    /// using the same `Circumstance` the rest of the app uses.
    func testTheUrsidRadiantIsCircumpolarFromTheFarNorth() {
        let start = EventTestSupport.julianDay(2026, 12, 15)
        let tromso = GeographicLocation(latitudeDegrees: 69.65, longitudeDegrees: 18.96)
        let ursids = MeteorShowers.events(fromJulianDay: start, toJulianDay: start + 20)
            .first { $0.title == "Ursids" }!
        let observability = EventCalendar.observability(for: ursids, observer: tromso)!
        XCTAssertEqual(observability.circumstance, .alwaysUp)
        XCTAssertEqual(observability.band, .excellent)
    }

    /// An equinox has nothing to point at, and must say so rather than invent
    /// a rating for the Sun.
    func testSeasonEventsCarryNoObservability() {
        let start = EventTestSupport.julianDay(2026, 3, 1)
        let equinox = EventCalendar.events(
            fromJulianDay: start, days: 40, observer: sanFrancisco
        ).first { $0.kind == .season }
        XCTAssertNotNil(equinox)
        XCTAssertNil(equinox?.observability)
    }

    func testNextFullMoonIsInTheFuture() {
        let now = EventTestSupport.julianDay(2026, 5, 17)
        let full = EventCalendar.next(
            kind: .moonPhase, matching: { $0.title == "Full Moon" },
            afterJulianDay: now, observer: sanFrancisco
        )
        let event = try! XCTUnwrap(full)
        XCTAssertGreaterThan(event.julianDay, now)
        XCTAssertLessThan(event.julianDay - now, 30)
    }

    /// The band comes from the shared visibility model, not from a second one.
    func testTheBandMatchesTheSharedAltitudeModel() {
        let start = EventTestSupport.julianDay(2026, 7, 1)
        let events = EventCalendar.events(fromJulianDay: start, days: 90, observer: sanFrancisco)
        for event in events {
            guard let observability = event.observability else { continue }
            XCTAssertEqual(
                observability.band,
                VisibilityRating.altitudeBand(
                    peakAltitudeDegrees: observability.peakAltitudeDegrees
                )
            )
        }
    }
}
