//
//  CatalogFreshnessTests.swift
//  AstronomyTests
//
//  Two things this file pins.
//
//  **The bundled element sets.** They were regenerated from a full-catalogue
//  mirror (see DATA_SOURCES.md) and their freshness is the single biggest
//  input to satellite positional accuracy. The tests below assert the shape of
//  the epoch distribution rather than a fixed date, so they stay meaningful as
//  the file is refreshed and still fail loudly if someone ships a snapshot
//  that has quietly rotted.
//
//  **The targeted refresh path.** The per-object lookup used when the bulk
//  sources are unreachable, and the text-level merge it writes through.
//

import XCTest
@testable import Astronomy

final class BundledCatalogFreshnessTests: XCTestCase {

    /// The bundled snapshot, parsed once per test.
    private func bundledElements() throws -> [TwoLineElement] {
        let url = try XCTUnwrap(
            Bundle(for: BundledCatalogFreshnessTests.self)
                .url(forResource: "satellites", withExtension: "txt")
                ?? Bundle.main.url(forResource: "satellites", withExtension: "txt"),
            "the bundled satellite catalogue is missing from the test bundle"
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        return TwoLineElement.parseCatalog(text)
    }

    func testCatalogueHasTheExpectedNumberOfObjects() throws {
        let elements = try bundledElements()
        // Regenerated at 16,348. A wide band, because the active catalogue
        // genuinely grows: this is a guard against a truncated or
        // half-written file, not a pin on the exact count.
        XCTAssertGreaterThan(elements.count, 14_000)
        XCTAssertLessThan(elements.count, 30_000)
    }

    func testCatalogueNumbersAreUnique() throws {
        let elements = try bundledElements()
        let numbers = Set(elements.map(\.catalogNumber))
        XCTAssertEqual(
            numbers.count, elements.count,
            "the same object appears twice — the merge that built this file "
            + "must key on catalogue number"
        )
    }

    func testEveryRecordIsAUsableElementSet() throws {
        let elements = try bundledElements()
        for element in elements {
            XCTAssertGreaterThan(element.catalogNumber, 0)
            // A mean motion of zero or a parabolic eccentricity means the
            // record parsed but is not something SGP4 can propagate.
            XCTAssertGreaterThan(element.meanMotionRevsPerDay, 0.01, "\(element.name)")
            XCTAssertLessThan(element.meanMotionRevsPerDay, 20.0, "\(element.name)")
            XCTAssertGreaterThanOrEqual(element.eccentricity, 0.0, "\(element.name)")
            XCTAssertLessThan(element.eccentricity, 1.0, "\(element.name)")
            XCTAssertGreaterThanOrEqual(element.inclinationDegrees, 0.0, "\(element.name)")
            XCTAssertLessThanOrEqual(element.inclinationDegrees, 180.0, "\(element.name)")
        }
    }

    func testEveryRecordInitialisesAPropagator() throws {
        let elements = try bundledElements()
        let satellites = elements.compactMap(Satellite.init(tle:))
        // A handful of pathological records failing to initialise would be
        // survivable, but a systematic problem would not.
        XCTAssertGreaterThan(
            Double(satellites.count) / Double(elements.count), 0.99,
            "too many bundled element sets fail SGP4 initialisation"
        )
    }

    func testTheISSIsPresentAndItsElementsAreFresh() throws {
        let elements = try bundledElements()
        let iss = try XCTUnwrap(
            elements.first { $0.catalogNumber == Satellite.issCatalogNumber },
            "the ISS is missing from the bundled catalogue"
        )
        XCTAssertTrue(iss.name.uppercased().contains("ISS"))

        // The ISS is the object most likely to be looked at and the one whose
        // low orbit decays fastest, so it is the one worth pinning hardest.
        // This is an age *at the time the snapshot was built*, measured
        // against the newest epoch in the file rather than against `now`, so
        // the assertion does not rot as the calendar advances.
        let newest = try XCTUnwrap(elements.map(\.epochJulianDay).max())
        XCTAssertLessThan(
            newest - iss.epochJulianDay, 2.0,
            "the ISS's elements are more than two days older than the freshest "
            + "in the file — it should be among the best-covered objects"
        )
    }

    func testMostOfTheCatalogueWasCurrentWhenTheSnapshotWasBuilt() throws {
        let elements = try bundledElements()
        let newest = try XCTUnwrap(elements.map(\.epochJulianDay).max())
        let ages = elements.map { newest - $0.epochJulianDay }.sorted()

        func percentile(_ p: Double) -> Double { ages[Int(Double(ages.count - 1) * p)] }

        // Regenerated file: median ~1.6 days, p90 ~8.5 days, max ~31 days.
        // The long tail is the ~5,000 objects the mirror does not carry, which
        // keep their older bundled elements rather than being dropped.
        XCTAssertLessThan(percentile(0.50), 4.0, "median epoch age has regressed")
        XCTAssertLessThan(percentile(0.90), 14.0, "the stale tail has grown")
        XCTAssertLessThan(ages.last ?? 0, 400.0,
                          "something very old got merged into the catalogue")
        XCTAssertGreaterThanOrEqual(ages.first ?? -1, -0.5,
                                    "an element set is dated in the future")
    }

    func testEveryNotableObjectIsInTheCatalogue() throws {
        let elements = try bundledElements()
        let numbers = Set(elements.map(\.catalogNumber))
        for notable in Satellite.notableCatalogNumbers {
            XCTAssertTrue(
                numbers.contains(notable),
                "notable object \(notable) is not in the bundled catalogue — "
                + "it would be silently useless in the notable list"
            )
        }
    }
}

final class TargetedElementSetRefreshTests: XCTestCase {

    private let issJSON = """
    {"@id":"https://tle.ivanstanojevic.me/api/tle/25544","satelliteId":25544,\
    "name":"ISS (ZARYA)","date":"2026-08-24T16:38:13+00:00",\
    "line1":"1 25544U 98067A   26236.69321429  .00007505  00000+0  14120-3 0  9992",\
    "line2":"2 25544  51.6332 321.0241 0007691  79.3790 280.8065 15.49608243582379"}
    """

    func testSingleObjectJSONBecomesThreeLineText() throws {
        let text = try SatelliteCatalogService.tleText(
            fromTargetedJSON: Data(issJSON.utf8)
        )
        let elements = TwoLineElement.parseCatalog(text)
        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements.first?.catalogNumber, 25544)
        XCTAssertEqual(elements.first?.name, "ISS (ZARYA)")
    }

    func testMalformedTargetedJSONThrowsRatherThanReturningRubbish() {
        XCTAssertThrowsError(
            try SatelliteCatalogService.tleText(fromTargetedJSON: Data("{}".utf8))
        )
        XCTAssertThrowsError(
            try SatelliteCatalogService.tleText(fromTargetedJSON: Data("not json".utf8))
        )
    }

    // MARK: - The text-level merge

    /// Two element sets for the same object, the second one a day later.
    private let older = """
    ISS (ZARYA)
    1 25544U 98067A   26235.69321429  .00007505  00000+0  14120-3 0  9995
    2 25544  51.6332 321.0241 0007691  79.3790 280.8065 15.49608243582379
    """
    private let newer = """
    ISS (ZARYA)
    1 25544U 98067A   26236.69321429  .00007505  00000+0  14120-3 0  9992
    2 25544  51.6332 321.0241 0007691  79.3790 280.8065 15.49608243582379
    """
    private let other = """
    HST
    1 20580U 90037B   26236.50000000  .00000700  00000+0  40000-4 0  9990
    2 20580  28.4700 100.0000 0002500 200.0000 160.0000 15.09000000000000
    """

    func testNewerElementsWin() {
        let merged = SatelliteCatalogService.mergeElementSetText(
            supplement: newer, onto: older
        )
        let elements = TwoLineElement.parseCatalog(merged)
        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements.first?.epochDayOfYear ?? 0, 236.69321429, accuracy: 1e-6)
    }

    func testOlderElementsNeverDragAnObjectBackwards() {
        // The whole point of the rule: a fallback source that happens to lag
        // must not undo a good refresh.
        let merged = SatelliteCatalogService.mergeElementSetText(
            supplement: older, onto: newer
        )
        let elements = TwoLineElement.parseCatalog(merged)
        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements.first?.epochDayOfYear ?? 0, 236.69321429, accuracy: 1e-6)
    }

    func testObjectsAbsentFromTheBaseAreAppendedAndBaseObjectsSurvive() {
        let merged = SatelliteCatalogService.mergeElementSetText(
            supplement: other, onto: newer
        )
        let numbers = Set(TwoLineElement.parseCatalog(merged).map(\.catalogNumber))
        XCTAssertEqual(numbers, [25544, 20580])
    }

    func testMergingOntoNothingKeepsEverything() {
        let merged = SatelliteCatalogService.mergeElementSetText(
            supplement: newer + "\n" + other, onto: ""
        )
        XCTAssertEqual(TwoLineElement.parseCatalog(merged).count, 2)
    }

    func testMergingNothingIsIdentity() {
        let merged = SatelliteCatalogService.mergeElementSetText(supplement: "", onto: newer)
        XCTAssertEqual(TwoLineElement.parseCatalog(merged).count, 1)
    }

    func testTheRecordLinesAreCarriedThroughByteForByte() {
        // The merge must never re-format an element set — a field-width or
        // checksum slip here would be invisible and would corrupt SGP4.
        let merged = SatelliteCatalogService.mergeElementSetText(
            supplement: newer, onto: other
        )
        XCTAssertTrue(
            merged.contains(
                "1 25544U 98067A   26236.69321429  .00007505  00000+0  14120-3 0  9992"
            )
        )
        XCTAssertTrue(
            merged.contains(
                "2 25544  51.6332 321.0241 0007691  79.3790 280.8065 15.49608243582379"
            )
        )
    }

    // MARK: - Politeness

    func testTheTargetedSweepIsBoundedSoItCannotBecomeABulkDownload() {
        // The same service can serve the whole catalogue in 257 requests. This
        // ceiling is what stops the targeted path drifting into doing that.
        XCTAssertLessThanOrEqual(SatelliteCatalogService.maximumTargetedRequests, 50)
        XCTAssertGreaterThanOrEqual(
            SatelliteCatalogService.maximumTargetedRequests,
            Satellite.notableCatalogNumbers.count,
            "the sweep must at least cover every notable object"
        )
        XCTAssertGreaterThan(SatelliteCatalogService.targetedRequestInterval, 0.05)
    }

    func testTheBulkSourcesAreUnchangedAndCelesTrakIsStillFirst() {
        // The targeted source is an addition, not a replacement.
        XCTAssertEqual(SatelliteCatalogService.sources.first?.name, "CelesTrak")
        XCTAssertTrue(SatelliteCatalogService.sources.first?.isComplete ?? false)
        XCTAssertEqual(SatelliteCatalogService.sources.count, 3)
        XCTAssertFalse(
            SatelliteCatalogService.sources.contains {
                $0.url.host?.contains("ivanstanojevic") ?? false
            },
            "the targeted mirror must never appear as a bulk source"
        )
    }
}
