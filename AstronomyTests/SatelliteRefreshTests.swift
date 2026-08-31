//
//  SatelliteRefreshTests.swift
//  AstronomyTests
//
//  The refresh that keeps satellite element sets current, tested where it
//  had never been tested: on a real disk.
//
//  This file exists because "the satellites are stale" came back three times.
//  Each time the diagnosis was a different broken link in the same chain, and
//  each time it survived a full green suite, because every existing test
//  stopped at the pure functions — the parsers and the text merge. Those were
//  always correct. What was broken was everything around them: a freshness
//  clock that read a file which never existed, a source loop that stopped at
//  the first partial success, and a cache directory
//  (`~/Library/Containers/com.shubhisrivastava.Astronomy/Data/Library/Application Support/Astronomy/`)
//  that was empty for the entire life of the project.
//
//  So the tests below write bytes and read them back. `ElementSetStore` is a
//  plain synchronous value type precisely so they can: no actor hop, no
//  expectation, no waiting.
//

import XCTest
@testable import Astronomy

final class ElementSetStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstronomyRefreshTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private func store() -> SatelliteCatalogService.ElementSetStore {
        SatelliteCatalogService.ElementSetStore(directory: directory)
    }

    /// Three-line TLE text for one object at a chosen epoch.
    ///
    /// Real ISS lines with the epoch field substituted, so the records parse
    /// through the same path the live ones do. The checksum digit is not
    /// verified by `TwoLineElement.parse`, which is why editing the epoch in
    /// place is safe here.
    private func elementSet(
        catalogNumber: Int = 25544, epoch: String, name: String = "ISS (ZARYA)"
    ) -> String {
        let line1 = "1 \(String(format: "%05d", catalogNumber))U 98067A   \(epoch)  .00005671  00000+0  11126-3 0  9990"
        let line2 = "2 \(String(format: "%05d", catalogNumber))  51.6316 292.2906 0005026  90.0365 270.1200 15.48938909583273"
        return "\(name)\n\(line1)\n\(line2)\n"
    }

    // MARK: - The thing that was never proved: bytes reach a disk

    func testTheSupplementIsGenuinelyWrittenAndReadBack() throws {
        let store = self.store()
        let url = try XCTUnwrap(store.supplementURL)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "the scratch directory must start empty or this test proves nothing"
        )

        let changed = try store.mergeIntoSupplement(elementSet(epoch: "26242.49847866"))
        XCTAssertTrue(changed)

        // The file. On disk. This assertion is the entire point of the file.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "the refresh reported success but wrote nothing"
        )
        let bytes = try Data(contentsOf: url)
        XCTAssertGreaterThan(bytes.count, 100)

        // And read back through the same call the loader makes.
        let elements = store.supplementElements()
        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements.first?.catalogNumber, 25544)
    }

    func testTheCacheIsGenuinelyWrittenAndReadBack() throws {
        let store = self.store()
        let url = try XCTUnwrap(store.cacheURL)
        XCTAssertNil(store.cachedCatalogText(), "no cache should exist yet")

        // Padded past the 1,000-character plausibility floor the loader
        // applies, with distinct catalogue numbers so it is a real catalogue
        // rather than the same record repeated.
        var text = ""
        for number in 25544..<25564 {
            text += elementSet(catalogNumber: number, epoch: "26242.49847866")
        }
        XCTAssertTrue(try store.writeCache(text))

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let readBack = try XCTUnwrap(store.cachedCatalogText())
        XCTAssertEqual(readBack, text)
        XCTAssertEqual(TwoLineElement.parseCatalog(readBack).count, 20)
    }

    /// A short cache is a truncated download, not a catalogue, and must not be
    /// allowed to stand in for the bundled snapshot.
    func testATruncatedCacheIsIgnoredRatherThanBelieved() throws {
        let store = self.store()
        try store.writeCache("nope")
        XCTAssertNil(store.cachedCatalogText())
    }

    // MARK: - Merging, on disk, across successive refreshes

    func testASecondPartialSourceAddsToTheFirstRatherThanReplacingIt() throws {
        let store = self.store()
        XCTAssertTrue(try store.mergeIntoSupplement(elementSet(catalogNumber: 25544, epoch: "26242.10000000")))
        XCTAssertTrue(try store.mergeIntoSupplement(elementSet(catalogNumber: 20580, epoch: "26242.20000000")))

        let numbers = Set(store.supplementElements().map(\.catalogNumber))
        XCTAssertEqual(
            numbers, [25544, 20580],
            "the second partial source overwrote the first instead of merging into it"
        )
    }

    func testAFresherElementSetWinsAndAStalerOneIsRejected() throws {
        let store = self.store()
        try store.mergeIntoSupplement(elementSet(epoch: "26242.50000000"))

        // A source that lags must not drag an object backwards.
        XCTAssertFalse(
            try store.mergeIntoSupplement(elementSet(epoch: "26240.50000000")),
            "a staler element set changed the file"
        )
        XCTAssertEqual(store.supplementElements().count, 1)
        let epoch = try XCTUnwrap(store.supplementElements().first?.epochJulianDay)

        XCTAssertTrue(try store.mergeIntoSupplement(elementSet(epoch: "26243.50000000")))
        let newer = try XCTUnwrap(store.supplementElements().first?.epochJulianDay)
        XCTAssertGreaterThan(newer, epoch)
    }

    /// Re-fetching identical elements must report "nothing changed", or the
    /// caller reloads sixteen thousand SGP4 propagators for no reason.
    func testAnUnchangedRefreshReportsNoChange() throws {
        let store = self.store()
        XCTAssertTrue(try store.mergeIntoSupplement(elementSet(epoch: "26242.49847866")))
        XCTAssertFalse(try store.mergeIntoSupplement(elementSet(epoch: "26242.49847866")))
    }

    // MARK: - The freshness clock

    func testFreshnessIsMeasuredAcrossBothFilesNotJustTheCache() throws {
        let store = self.store()
        XCTAssertNil(store.lastRefreshAge(), "nothing written yet")

        // Only the supplement is written — which is the *normal* state of this
        // app whenever the one complete source is unreachable. The old code
        // measured the cache alone, got nil here, computed a zero delay, and
        // re-ran the whole refresh every thirty seconds forever.
        try store.mergeIntoSupplement(elementSet(epoch: "26242.49847866"))
        let age = try XCTUnwrap(
            store.lastRefreshAge(),
            "a supplement-only refresh left the freshness clock unset, which is the bug that made the loop poll"
        )
        XCTAssertLessThan(age, 60)
        XCTAssertGreaterThanOrEqual(age, 0)
    }

    func testAFreshSupplementSuppressesAnotherRefreshForADay() throws {
        let store = self.store()
        try store.mergeIntoSupplement(elementSet(epoch: "26242.49847866"))
        let age = try XCTUnwrap(store.lastRefreshAge())
        XCTAssertLessThan(
            age, SatelliteCatalogService.minimumRefreshInterval,
            "a refresh that has just written must not be considered due again"
        )
    }
}

// MARK: - Scheduling, priority and backoff

final class SatelliteRefreshSchedulingTests: XCTestCase {

    /// The objects overhead right now come before the curated notable list,
    /// and the whole sweep stays inside its ceiling.
    func testTheSweepFetchesWhatIsOverheadBeforeTheNotableList() {
        let overhead = [99001, 99002, 99003]
        let ordered = SatelliteCatalogService.priorityCatalogNumbers(including: overhead)

        XCTAssertEqual(Array(ordered.prefix(3)), overhead)
        XCTAssertTrue(
            ordered.contains(25544),
            "the ISS must still be swept even when nothing of ours is overhead"
        )
        XCTAssertLessThanOrEqual(ordered.count, SatelliteCatalogService.maximumTargetedRequests)
    }

    func testThePrioritySweepNeverAsksForTheSameObjectTwice() {
        // The ISS is both notable and, frequently, overhead. One request.
        let ordered = SatelliteCatalogService.priorityCatalogNumbers(including: [25544, 25544, 20580])
        XCTAssertEqual(Set(ordered).count, ordered.count)
        XCTAssertEqual(ordered.first, 25544)
    }

    func testThePrioritySweepIsCappedEvenWhenTheSkyIsFull() {
        let manyOverhead = Array(90000..<90500)
        let ordered = SatelliteCatalogService.priorityCatalogNumbers(including: manyOverhead)
        XCTAssertEqual(ordered.count, SatelliteCatalogService.maximumTargetedRequests)
    }

    func testWithNoPriorityHintTheNotableListIsStillSwept() {
        let ordered = SatelliteCatalogService.priorityCatalogNumbers(including: [])
        XCTAssertFalse(ordered.isEmpty)
        XCTAssertTrue(ordered.allSatisfy { Satellite.notableCatalogNumbers.contains($0) })
    }

    // MARK: - Rate limiting

    /// The mirror answers 508 ("resource limit is reached") under load rather
    /// than the 429 one might expect, and shared hosts commonly use 503. All
    /// three mean the same thing and all three must stop the sweep.
    func testTheStatusCodesThatMeanStopAsking() {
        for code in [429, 503, 508] {
            XCTAssertTrue(
                SatelliteCatalogService.rateLimitStatusCodes.contains(code),
                "\(code) must be treated as a rate limit, not as an ordinary failure"
            )
        }
        for code in [200, 301, 404, 500] {
            XCTAssertFalse(SatelliteCatalogService.rateLimitStatusCodes.contains(code))
        }
    }

    /// A rate limit is a distinct error precisely so the paged sweep can tell
    /// "this page failed" from "stop asking this host".
    func testARateLimitIsItsOwnError() {
        XCTAssertNotNil(SatelliteCatalogService.RefreshError.rateLimited.errorDescription)
    }

    // MARK: - The two gates

    func testTheAgingGateFiresOnceElementsAreNoLongerFresh() {
        XCTAssertFalse(SatelliteCatalogService.elementsAreAging(ageDays: nil))
        XCTAssertFalse(SatelliteCatalogService.elementsAreAging(ageDays: 0.5))
        XCTAssertFalse(
            SatelliteCatalogService.elementsAreAging(
                ageDays: ElementSetStaleness.freshLimitDays - 0.01
            )
        )
        XCTAssertTrue(
            SatelliteCatalogService.elementsAreAging(
                ageDays: ElementSetStaleness.freshLimitDays + 0.01
            )
        )
        XCTAssertTrue(SatelliteCatalogService.elementsAreAging(ageDays: 6.1))
    }

    /// The aging gate shortens the wait; it must never remove it. Without a
    /// floor of its own, elements that stay stale because the network is down
    /// would make the loop retry continuously.
    func testTheAgingGateStillHasAFloor() {
        XCTAssertGreaterThan(SatelliteCatalogService.agingRefreshInterval, 0)
        XCTAssertLessThan(
            SatelliteCatalogService.agingRefreshInterval,
            SatelliteCatalogService.minimumRefreshInterval
        )
        XCTAssertGreaterThanOrEqual(
            SatelliteCatalogService.agingRefreshInterval, 15 * 60,
            "an aging catalogue is not a reason to poll"
        )
    }

    // MARK: - Backoff

    func testFailuresBackOffExponentiallyAndCap() {
        // The schedule the service applies: initial * 2^(n-1), capped.
        var previous = 0.0
        for failures in 1...12 {
            let scale = pow(2.0, Double(min(failures - 1, 10)))
            let delay = min(
                SatelliteCatalogService.maximumRetryInterval,
                SatelliteCatalogService.initialRetryInterval * scale
            )
            XCTAssertGreaterThanOrEqual(delay, previous)
            XCTAssertLessThanOrEqual(delay, SatelliteCatalogService.maximumRetryInterval)
            previous = delay
        }
        XCTAssertEqual(previous, SatelliteCatalogService.maximumRetryInterval)
    }

    // MARK: - Politeness of the bulk sweep

    func testTheBulkSweepIsBoundedAndSpaced() {
        let source = try? XCTUnwrap(SatelliteCatalogService.pagedSources.first)
        guard let source = source else { return XCTFail("no paged source configured") }

        XCTAssertEqual(source.pageSize, 100, "the service caps page-size at 100")
        // 25,700 objects at 100 per page is ~258 pages; the ceiling has to
        // clear that with headroom and still be a ceiling.
        XCTAssertGreaterThan(source.maximumPages, 258)
        XCTAssertLessThanOrEqual(source.maximumPages, 400)

        XCTAssertGreaterThanOrEqual(
            SatelliteCatalogService.pageRequestInterval, 0.25,
            "258 unspaced requests is not a polite thing to do to a free mirror"
        )
        // The whole sweep, once a day, should be a couple of minutes of
        // background traffic — not an hour.
        let sweepSeconds = Double(source.maximumPages) * SatelliteCatalogService.pageRequestInterval
        XCTAssertLessThan(sweepSeconds, 5 * 60)

        XCTAssertGreaterThan(SatelliteCatalogService.pageFlushInterval, 1)
        XCTAssertLessThanOrEqual(
            SatelliteCatalogService.pageFlushInterval, 25,
            "an interrupted sweep must not throw away much of what it fetched"
        )
    }

    func testTheBulkSweepUsesACollectionEndpointThatWillNotRedirect() throws {
        let source = try XCTUnwrap(SatelliteCatalogService.pagedSources.first)
        // Without the trailing slash the service answers 301 and the query
        // string is lost on the redirect — which is exactly how this source
        // was first written off as unreachable.
        XCTAssertTrue(
            source.baseURL.absoluteString.hasSuffix("/"),
            "the collection endpoint needs its trailing slash or the paging parameters are dropped"
        )
        XCTAssertEqual(source.baseURL.scheme, "https")
    }

    // MARK: - Parsing what the bulk endpoint actually returns

    func testTheCollectionResponseBecomesParseableTLEText() throws {
        // Shape and field names taken from a live response.
        let json = """
        {
          "@context": "https://www.w3.org/ns/hydra/context.jsonld",
          "@type": "Collection",
          "totalItems": 25706,
          "member": [
            {
              "@id": "https://tle.ivanstanojevic.me/api/tle/25544",
              "satelliteId": 25544,
              "name": "ISS (ZARYA)",
              "date": "2026-08-30T11:57:48+00:00",
              "line1": "1 25544U 98067A   26242.49847866  .00005671  00000+0  11126-3 0  9990",
              "line2": "2 25544  51.6316 292.2906 0005026  90.0365 270.1200 15.48938909583273"
            },
            {
              "satelliteId": 20580,
              "name": "HST",
              "line1": "1 20580U 90037B   26242.24812500  .00002182  00000+0  11815-3 0  9992",
              "line2": "2 20580  28.4700 288.8102 0002481 306.6062 143.1969 15.11148768773344"
            }
          ]
        }
        """
        let text = try SatelliteCatalogService.tleText(fromCollectionJSON: Data(json.utf8))
        let elements = TwoLineElement.parseCatalog(text)
        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual(elements.first?.catalogNumber, 25544)
        XCTAssertEqual(elements.first?.name, "ISS (ZARYA)")
        XCTAssertEqual(elements.last?.catalogNumber, 20580)
    }

    /// Past the end of the collection the service answers an empty member
    /// array. That is how the sweep knows to stop, so it must not throw.
    func testAnEmptyPageEndsTheSweepRatherThanFailingIt() throws {
        let text = try SatelliteCatalogService.tleText(
            fromCollectionJSON: Data(#"{"totalItems": 25706, "member": []}"#.utf8)
        )
        XCTAssertEqual(TwoLineElement.parseCatalog(text).count, 0)
    }

    func testAnErrorPageIsRejectedRatherThanStored() {
        // A rate-limited mirror serves HTML. It must not reach the merge.
        XCTAssertThrowsError(
            try SatelliteCatalogService.tleText(
                fromCollectionJSON: Data("<html>508 Resource Limit Is Reached</html>".utf8)
            )
        )
        XCTAssertThrowsError(
            try SatelliteCatalogService.tleText(fromCollectionJSON: Data(#"{"member": "nope"}"#.utf8))
        )
    }

    // MARK: - No network at all

    /// With every source unreachable the app must still show a sky: the
    /// bundled snapshot loads, the supplement (if any) overlays it, and the
    /// staleness wording carries the consequence. Nothing here touches the
    /// network, which is the point — this is the offline path.
    func testWithNoNetworkTheBundledCatalogueStillLoadsAndSaysItIsStale() throws {
        let url = try XCTUnwrap(
            Bundle(for: SatelliteRefreshSchedulingTests.self)
                .url(forResource: "satellites", withExtension: "txt")
                ?? Bundle.main.url(forResource: "satellites", withExtension: "txt")
        )
        let elements = TwoLineElement.parseCatalog(try String(contentsOf: url, encoding: .utf8))
        XCTAssertGreaterThan(elements.count, 14_000)

        // And a catalogue this old is labelled, not silently trusted. Both
        // gates survive: they are what the user sees when the network is gone
        // and there is genuinely nothing better to show.
        XCTAssertEqual(SatelliteAccuracy.staleness(ageDays: 0.5), .fresh)
        XCTAssertEqual(SatelliteAccuracy.staleness(ageDays: 6.1), .aging)
        XCTAssertEqual(SatelliteAccuracy.staleness(ageDays: 30), .unreliable)
        XCTAssertNotNil(ElementSetStaleness.aging.caveat)
        XCTAssertNotNil(ElementSetStaleness.unreliable.caveat)
    }

    /// An offline store answers every question without throwing and without
    /// pretending it has anything.
    func testAnEmptyStoreIsHonestRatherThanBroken() {
        let store = SatelliteCatalogService.ElementSetStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("AstronomyRefreshTests-absent-\(UUID().uuidString)")
        )
        XCTAssertNil(store.cachedCatalogText())
        XCTAssertNil(store.supplementText())
        XCTAssertTrue(store.supplementElements().isEmpty)
        XCTAssertNil(store.lastRefreshAge())
    }

    /// And a store with nowhere to write refuses rather than crashing.
    func testAStoreWithNoDirectoryDeclinesEverything() throws {
        let store = SatelliteCatalogService.ElementSetStore(directory: nil)
        XCTAssertNil(store.cacheURL)
        XCTAssertNil(store.supplementURL)
        XCTAssertFalse(try store.writeCache("anything"))
        XCTAssertFalse(try store.mergeIntoSupplement("anything"))
        XCTAssertNil(store.lastRefreshAge())
    }

    // MARK: - The real container path

    /// The app's actual storage location is writable, and the service points
    /// at it.
    ///
    /// This is the assertion that would have caught the original failure. The
    /// container directory
    /// (`~/Library/Containers/com.shubhisrivastava.Astronomy/Data/Library/Application Support/Astronomy/`)
    /// was empty for the entire life of the project, and nothing in the suite
    /// had an opinion about that. A probe file is used rather than the real
    /// cache so running the tests cannot disturb the user's own element sets.
    func testTheRealSupportDirectoryIsWritable() throws {
        let directory = try XCTUnwrap(
            SatelliteCatalogService.defaultSupportDirectory,
            "the app has no writable Application Support directory"
        )
        XCTAssertTrue(directory.path.hasSuffix("Application Support/Astronomy"))

        let probe = directory.appendingPathComponent("refresh-writability-probe.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: probe) }

        try Data("probe".utf8).write(to: probe, options: .atomic)
        XCTAssertEqual(try String(contentsOf: probe, encoding: .utf8), "probe")
    }
}
