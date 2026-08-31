//
//  SatelliteCatalogService.swift
//  Astronomy
//
//  Loads the satellite element-set catalogue, offline first, and keeps it as
//  fresh as the network allows.
//
//  What is loaded, in order:
//    1. a cached full-catalogue download in Application Support, if present,
//       otherwise the snapshot bundled with the app,
//    2. overlaid with a *supplement* file — a smaller, fresher set from a
//       fallback source — for the objects it covers.
//
//  The overlay exists because the fallback sources are partial. SatNOGS
//  publishes roughly 1,700 element sets, not 16,000; replacing the cache with
//  them would trade 16,000 stale objects for 1,700 fresh ones. Overlaying
//  keeps both: every object the app ever knew about, with the freshest
//  elements available for each.
//
//  Refresh is attempted repeatedly within a session, not once per launch, and
//  from more than one host. That is the direct fix for the failure this
//  replaced: a single source, tried once, failing silently, meaning the app ran
//  off its bundled snapshot indefinitely and eventually hid every satellite.
//
//  Element sets go stale. See DATA_SOURCES.md and `ElementSetStaleness` for the
//  accuracy consequences, which are real, are graduated, and are surfaced in
//  the satellite control and the info panel rather than being hidden behind a
//  blank sky.
//

import Foundation
import os

actor SatelliteCatalogService {

    static let shared = SatelliteCatalogService()

    /// Where the cache and supplement live. Injectable so a test can exercise
    /// the *real* write-then-read-back path against a scratch directory
    /// instead of the user's own files.
    ///
    /// This is not decoration. The refresh in this app failed silently from
    /// the day it was written, and the reason it went unnoticed for three
    /// rounds of "satellites are stale again" is that every test covered the
    /// pure functions — the parsers, the merge — and none of them ever put a
    /// byte on a disk. A test that only checks the code path is not evidence
    /// that the code path works.
    let supportDirectory: URL?

    init(supportDirectory: URL? = SatelliteCatalogService.defaultSupportDirectory) {
        self.supportDirectory = supportDirectory
    }

    /// A place element sets can be fetched from.
    ///
    /// Every one of these is a public, no-credentials, redistributable feed.
    /// Space-Track is deliberately absent: it is the authoritative source but
    /// requires an account, and bundling credentials in a shipping app is not
    /// something this app is going to do.
    struct Source: Sendable {
        let name: String
        let url: URL
        /// How the response body becomes TLE text.
        let format: Format
        /// Fewest parseable element sets a response must carry to be believed.
        /// Per source, because the sources differ in size by two orders of
        /// magnitude and one threshold cannot serve both.
        let minimumElementSets: Int
        /// True for a source that carries the whole catalogue and may therefore
        /// replace the cache outright. False for a partial source, which is
        /// written to the supplement file and overlaid instead.
        let isComplete: Bool

        enum Format: Sendable {
            /// Plain three-line TLE text, as CelesTrak and AMSAT serve it.
            case tleText
            /// SatNOGS' JSON array of `{tle0, tle1, tle2}` objects.
            case satnogsJSON
        }
    }

    /// Sources in preference order.
    ///
    /// CelesTrak first because it is the complete catalogue and the one this
    /// app was built around. The other two are partial but real: SatNOGS
    /// republishes ~1,700 element sets (mostly Space-Track-derived) through an
    /// open API, and AMSAT publishes the ~100 amateur-radio objects. Both were
    /// fetched and checked while this was written: both parse as TLEs and both
    /// carry current epochs, including the ISS.
    static let sources: [Source] = [
        Source(
            name: "CelesTrak",
            url: URL(string: "https://celestrak.org/NORAD/elements/gp.php?GROUP=active&FORMAT=tle")!,
            format: .tleText,
            minimumElementSets: 1000,
            isComplete: true
        ),
        Source(
            name: "SatNOGS",
            url: URL(string: "https://db.satnogs.org/api/tle/?format=json")!,
            format: .satnogsJSON,
            minimumElementSets: 200,
            isComplete: false
        ),
        Source(
            name: "AMSAT",
            url: URL(string: "https://www.amsat.org/tle/current/nasabare.txt")!,
            format: .tleText,
            minimumElementSets: 30,
            isComplete: false
        ),
    ]

    /// Base URL of the per-object lookup. Appending a catalogue number returns
    /// that one object's current element set as JSON.
    ///
    /// It is a third-party mirror of Space-Track's public-domain US Government
    /// element sets, not an authority in its own right. See DATA_SOURCES.md.
    static let targetedSourceName = "TLE API (ivanstanojevic.me)"
    static let targetedSourceBaseURL = URL(string: "https://tle.ivanstanojevic.me/api/tle/")!

    // MARK: - The paged mirror

    /// A source that serves the whole catalogue, but only a page at a time.
    ///
    /// This exists because the premise the original design rested on — that
    /// CelesTrak is the dependable primary and everything else is an emergency
    /// stopgap — turned out to be false in practice. CelesTrak has been
    /// unreachable from this machine for days at a stretch (DNS resolves, the
    /// TCP connection to :443 times out), and a bundled snapshot ages past
    /// "fresh" within 48 hours. "Always up to date" cannot be delivered by a
    /// snapshot plus a source that is down; it can only be delivered by a
    /// refresh path that actually completes.
    ///
    /// So the mirror is promoted from "a handful of targeted lookups after
    /// everything else failed" to a real bulk path. 25,700 objects at 100 per
    /// page is ~258 requests. That is a lot to ask in one breath, which is why
    /// it is spaced (`pageInterval`), capped (`maximumPages`), run at
    /// background priority, written incrementally so partial progress is never
    /// thrown away, and abandoned immediately if the service pushes back.
    ///
    /// It runs at most once a day. 258 spaced requests once a day is a smaller
    /// load than the old code was placing on AMSAT, which — because
    /// `nextRefreshDelay` measured freshness by the mtime of a cache file that
    /// never existed — was being re-fetched every thirty seconds for the life
    /// of the process. That bug is fixed below (`lastRefreshAge`).
    struct PagedSource: Sendable {
        let name: String
        /// Collection endpoint. The trailing slash matters: without it the
        /// service answers 301 and `URLSession` drops the query string on the
        /// redirect, which is how this looked "unreachable" the first time.
        let baseURL: URL
        let pageSize: Int
        /// Hard ceiling on pages per sweep, so a change at the far end can
        /// never turn this into an unbounded crawl.
        let maximumPages: Int
        /// Fewest element sets a completed sweep must yield to be believed.
        let minimumElementSets: Int
    }

    static let pagedSources: [PagedSource] = [
        PagedSource(
            name: targetedSourceName,
            baseURL: targetedSourceBaseURL,
            pageSize: 100,
            maximumPages: 300,
            minimumElementSets: 500
        )
    ]

    /// Pause between pages of a bulk sweep. 258 pages at this spacing is about
    /// a minute and a half of traffic, once a day.
    static let pageRequestInterval: TimeInterval = 0.35

    /// How often the accumulated pages are flushed to disk mid-sweep. Small
    /// enough that an interrupted sweep — a rate limit, a closed lid, a quit —
    /// keeps nearly everything it fetched, large enough that this is not a
    /// write per request.
    static let pageFlushInterval = 10

    /// Ceiling on how many objects one targeted sweep may request, so this can
    /// never quietly grow into a bulk download. The notable list is 19 objects;
    /// the selected satellite may add one more.
    static let maximumTargetedRequests = 40

    /// Pause between targeted requests. Twenty per sweep at this spacing is
    /// about eight seconds of traffic, once, after a bulk failure.
    static let targetedRequestInterval: TimeInterval = 0.4

    /// These services ask clients not to poll aggressively and to identify
    /// themselves. Both are honoured: this User-Agent is descriptive, and
    /// `minimumRefreshInterval` is a hard floor of one day between *successful*
    /// refreshes.
    static let userAgent = "Astronomy-macOS-Planetarium/1.0 (satellite tracking; TLE refresh once per day)"

    /// Element sets are re-issued at most a few times a day and the app's
    /// accuracy is limited by other things long before it is limited by a few
    /// hours of element age. One day is both polite and sufficient.
    static let minimumRefreshInterval: TimeInterval = 24 * 60 * 60

    /// The shorter floor that applies when the loaded elements have already
    /// aged past `ElementSetStaleness.freshLimitDays`. Still an hour, so a run
    /// of partial successes cannot turn into a poll: this shortens the wait,
    /// it does not remove it.
    static let agingRefreshInterval: TimeInterval = 60 * 60

    /// Backoff after a *failed* attempt. Starts at a minute so a transient
    /// outage — a laptop opened before the Wi-Fi associates, which is the
    /// commonest case by far — heals in about the time it takes to notice the
    /// sky is up, and caps at half an hour so a long outage costs almost
    /// nothing. Failures never touch the one-day floor, which only governs
    /// success.
    static let initialRetryInterval: TimeInterval = 60
    static let maximumRetryInterval: TimeInterval = 30 * 60

    private static let logger = Logger(subsystem: "Astronomy", category: "satellites")

    private var cachedSatellites: [Satellite]?
    /// Consecutive failed refresh attempts, for the backoff schedule.
    private var consecutiveFailures = 0

    // MARK: - Refresh status, as the UI sees it

    /// What the last refresh attempt did. Published so the satellite control
    /// can say it out loud: the whole reason this went unnoticed for so long is
    /// that failure was visible only in a log nobody reads.
    struct RefreshStatus: Sendable, Equatable {
        /// Human-readable failure summary, or nil when the last attempt worked
        /// (or none has run yet).
        var lastError: String?
        /// Name of the source that last supplied elements, if any.
        var lastSuccessfulSource: String?
        var lastSuccess: Date?
        var lastAttempt: Date?
        var consecutiveFailures = 0

        /// True when the app has tried and failed and has nothing newer than
        /// what it shipped with.
        var isFailing: Bool { lastError != nil }
    }

    private(set) var refreshStatus = RefreshStatus()
    private(set) var lastRefreshError: String? { didSet { refreshStatus.lastError = lastRefreshError } }
    /// Provenance of whatever is currently loaded, for diagnostics.
    private(set) var loadedFromCache = false

    // MARK: - Loading

    /// Loads (and caches in memory) the satellite catalogue. Parsing 16,000
    /// element sets and initialising 16,000 SGP4 records happens here, on this
    /// actor's executor, never on the main thread.
    func loadSatellites() async throws -> [Satellite] {
        if let cachedSatellites { return cachedSatellites }

        let text = try loadCatalogText()
        var elements = TwoLineElement.parseCatalog(text)
        elements = Self.overlay(supplement: loadSupplementElements(), onto: elements)
        // A satellite whose elements cannot be initialised (degenerate mean
        // motion, eccentricity out of range) is dropped rather than rendered
        // from a propagator that never converged.
        let satellites = elements.compactMap(Satellite.init(tle:))
        Self.logger.info("Loaded \(satellites.count) satellites from \(elements.count) element sets")
        cachedSatellites = satellites
        return satellites
    }

    /// Cached-then-bundled text, with no network access.
    private func loadCatalogText() throws -> String {
        if let cacheURL = cacheFileURL,
           let data = try? Data(contentsOf: cacheURL),
           let text = String(data: data, encoding: .utf8),
           text.count > 1000 {
            loadedFromCache = true
            return text
        }
        loadedFromCache = false
        guard let url = Bundle.main.url(forResource: "satellites", withExtension: "txt") else {
            throw CatalogServiceError.resourceNotFound("satellites")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func loadSupplementElements() -> [TwoLineElement] {
        guard let url = supplementFileURL,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return TwoLineElement.parseCatalog(text)
    }

    /// Merges a partial, fresher element set over a complete, older one.
    ///
    /// Keyed by catalogue number, and *only* where the supplement is genuinely
    /// newer — a fallback source that happens to lag the cache must not drag
    /// an object backwards. Objects the supplement knows about and the base
    /// does not are appended: they are real satellites the base file simply
    /// missed.
    static func overlay(
        supplement: [TwoLineElement], onto base: [TwoLineElement]
    ) -> [TwoLineElement] {
        guard !supplement.isEmpty else { return base }
        var indexByCatalogNumber: [Int: Int] = [:]
        indexByCatalogNumber.reserveCapacity(base.count)
        for (index, element) in base.enumerated() {
            indexByCatalogNumber[element.catalogNumber] = index
        }
        var merged = base
        for element in supplement {
            if let index = indexByCatalogNumber[element.catalogNumber] {
                if element.epochJulianDay > merged[index].epochJulianDay {
                    merged[index] = element
                }
            } else {
                indexByCatalogNumber[element.catalogNumber] = merged.count
                merged.append(element)
            }
        }
        return merged
    }

    // MARK: - Refresh

    /// How long to wait before the next refresh attempt, given what has
    /// happened so far. `nil` means "nothing to do": the cache is fresh and
    /// nothing has failed.
    func nextRefreshDelay() -> TimeInterval? {
        if consecutiveFailures > 0 {
            let scale = pow(2.0, Double(min(consecutiveFailures - 1, 10)))
            return min(Self.maximumRetryInterval, Self.initialRetryInterval * scale)
        }
        guard let age = lastRefreshAge() else { return 0 }
        return max(0, Self.minimumRefreshInterval - age)
    }

    /// Seconds since the full cache was written, or nil if there is no cache.
    private func cacheAge() -> TimeInterval? {
        Self.age(of: cacheFileURL)
    }

    /// Seconds since *anything* was last written by a refresh — the full cache
    /// or the supplement, whichever is newer.
    ///
    /// This is the freshness measure `refreshIfStale` actually uses, and
    /// replacing `cacheAge` with it fixes a live bug. `cacheAge` reads the
    /// mtime of the full-catalogue file, which is only ever written by a
    /// *complete* source. With CelesTrak unreachable that file never existed,
    /// so `cacheAge()` returned nil, so `nextRefreshDelay()` returned 0, so the
    /// refresh loop re-ran every thirty seconds for the life of the process —
    /// re-downloading AMSAT's element sets roughly 2,800 times a day. The
    /// one-day floor was never in force, because the thing it was measuring
    /// was never there.
    func lastRefreshAge() -> TimeInterval? {
        let ages = [Self.age(of: cacheFileURL), Self.age(of: supplementFileURL)].compactMap { $0 }
        return ages.min()
    }

    private static func age(of url: URL?) -> TimeInterval? {
        guard let url,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(modified)
    }

    /// Fetches fresh element sets if the cache is older than a day, trying each
    /// source in turn. Returns true when something on disk actually changed.
    ///
    /// Never throws: a network failure must not be able to break the sky.
    @discardableResult
    func refreshIfStale(
        priorityCatalogNumbers: [Int] = [],
        elementAgeDays: Double? = nil
    ) async -> Bool {
        if consecutiveFailures == 0, let age = lastRefreshAge() {
            let floor = Self.elementsAreAging(ageDays: elementAgeDays)
                ? Self.agingRefreshInterval
                : Self.minimumRefreshInterval
            if age < floor { return false }
        }
        return await refresh(priorityCatalogNumbers: priorityCatalogNumbers)
    }

    /// True when the *elements themselves* — not the file they arrived in —
    /// have drifted into the "aging" band and are worth another attempt even
    /// though the one-day floor has not elapsed.
    ///
    /// The two clocks are genuinely different. A successful refresh writes a
    /// file, but the elements it wrote may already have been a day old at the
    /// source, and a partial refresh leaves most of the catalogue at whatever
    /// age it already was. Gating only on "when did we last write a file"
    /// meant the app could sit on elements it *knew* were degrading for
    /// another twenty-three hours. This is the second of the two gates the
    /// user asked to keep: with a working bulk path it should almost never
    /// fire, and when it does it is because something is genuinely wrong.
    static func elementsAreAging(ageDays: Double?) -> Bool {
        guard let ageDays else { return false }
        return ageDays > ElementSetStaleness.freshLimitDays
    }

    /// Unconditional refresh attempt across every source, best first.
    ///
    /// Stops at the first source that yields a plausible element-set file. A
    /// complete source replaces the cache; a partial one is written to the
    /// supplement file and overlaid at load time, so falling back never costs
    /// the user 14,000 objects.
    /// Unconditional refresh attempt, in priority order.
    ///
    /// The order is chosen so the user gets the benefit immediately rather
    /// than in three minutes' time:
    ///
    ///  1. **The complete source, if it is up.** CelesTrak in one request is
    ///     still by far the best outcome and is tried first every time.
    ///  2. **The objects that matter, one at a time.** The notable list plus
    ///     whatever is above the horizon right now — a few dozen requests,
    ///     about ten seconds. If the user is watching the ISS, the ISS is
    ///     current before the long tail has started.
    ///  3. **The other partial bulk sources**, all of them, merged. This used
    ///     to stop at the first success, which is why the app had been running
    ///     on AMSAT's ninety-nine amateur-radio objects: SatNOGS (~1,700
    ///     objects) was timing out, AMSAT answered, and the loop returned. A
    ///     partial source is not a substitute for another partial source and
    ///     there is no reason to choose between them.
    ///  4. **The paged mirror, the whole catalogue.** ~258 spaced requests,
    ///     flushed to disk as it goes.
    ///
    /// Never throws: a network failure must not be able to break the sky. The
    /// return value is "something on disk changed, reload", not "everything
    /// worked" — those are different questions and the UI asks the second one
    /// through `refreshStatus`.
    @discardableResult
    func refresh(priorityCatalogNumbers: [Int] = []) async -> Bool {
        refreshStatus.lastAttempt = Date()
        var failures: [String] = []
        var changed = false
        var succeededWith: String?

        // 1. The complete source.
        for source in Self.sources where source.isComplete {
            do {
                if try await fetchAndStore(source) {
                    // A complete catalogue supersedes everything; there is
                    // nothing the partial sources could add.
                    consecutiveFailures = 0
                    lastRefreshError = nil
                    refreshStatus.consecutiveFailures = 0
                    refreshStatus.lastSuccess = Date()
                    refreshStatus.lastSuccessfulSource = source.name
                    return true
                }
                failures.append("\(source.name): response did not look like an element-set file")
            } catch {
                failures.append("\(source.name): \(error.localizedDescription)")
            }
        }

        // 2. The objects a user is actually looking at.
        if await refreshTargeted(catalogNumbers: Self.priorityCatalogNumbers(including: priorityCatalogNumbers)) {
            changed = true
            succeededWith = Self.targetedSourceName
        }

        // 3. Every partial bulk source, merged rather than raced.
        for source in Self.sources where !source.isComplete {
            do {
                if try await fetchAndStore(source) {
                    changed = true
                    succeededWith = source.name
                } else {
                    failures.append("\(source.name): response did not look like an element-set file")
                }
            } catch {
                failures.append("\(source.name): \(error.localizedDescription)")
            }
        }

        // 4. The long tail.
        for source in Self.pagedSources {
            do {
                if try await refreshPaged(source) {
                    changed = true
                    succeededWith = source.name
                }
            } catch {
                failures.append("\(source.name): \(error.localizedDescription)")
            }
        }

        if changed {
            consecutiveFailures = 0
            lastRefreshError = failures.isEmpty ? nil : failures.first
            refreshStatus.consecutiveFailures = 0
            refreshStatus.lastSuccess = Date()
            refreshStatus.lastSuccessfulSource = succeededWith
            if !failures.isEmpty {
                Self.logger.notice(
                    "Satellite refresh partially succeeded via \(succeededWith ?? "?"): \(failures.joined(separator: "; "))"
                )
            }
            return true
        }

        consecutiveFailures += 1
        refreshStatus.consecutiveFailures = consecutiveFailures
        lastRefreshError = failures.first ?? "no element-set source could be reached"
        Self.logger.notice(
            "Satellite refresh failed, keeping existing elements: \(failures.joined(separator: "; "))"
        )
        return false
    }

    /// Fetches one bulk source and writes it where it belongs. Returns false
    /// (rather than throwing) when the body arrived but did not look like
    /// element sets.
    private func fetchAndStore(_ source: Source) async throws -> Bool {
        let text = try await fetch(source)
        let elements = TwoLineElement.parseCatalog(text)
        // Sanity-check before overwriting a working cache: CelesTrak serves an
        // HTML error page on rate limiting, and a 300-byte "slow down" must not
        // replace 16,000 good element sets.
        guard elements.count >= source.minimumElementSets else { return false }
        if source.isComplete {
            guard let destination = cacheFileURL else { return false }
            try write(text, to: destination)
        } else {
            // Merged, not overwritten: two partial sources cover different
            // objects and each must be able to add to what the other left.
            guard let destination = supplementFileURL else { return false }
            let existing = (try? String(contentsOf: destination, encoding: .utf8)) ?? ""
            let merged = Self.mergeElementSetText(supplement: text, onto: existing)
            guard merged != existing else { return false }
            try write(merged, to: destination)
        }
        Self.logger.info(
            "Refreshed \(elements.count) satellite element sets from \(source.name)"
        )
        return true
    }

    private func write(_ text: String, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: destination, options: .atomic)
    }

    /// Which objects the priority sweep covers: whatever the caller says is
    /// interesting right now (sunlit and above the horizon), then the curated
    /// notable list, deduplicated and capped.
    ///
    /// Caller-supplied numbers come first deliberately. The notable list is a
    /// good guess about what someone might look for; what is actually over
    /// their head at this moment is not a guess.
    static func priorityCatalogNumbers(including caller: [Int]) -> [Int] {
        var seen = Set<Int>()
        var out: [Int] = []
        for number in caller + Satellite.notableCatalogNumbers.sorted() {
            guard seen.insert(number).inserted else { continue }
            out.append(number)
            if out.count == maximumTargetedRequests { break }
        }
        return out
    }

    /// Walks a paged source to the end of the catalogue, merging as it goes.
    ///
    /// Three properties matter here and each is a deliberate choice:
    ///
    ///  * **It flushes.** Every `pageFlushInterval` pages the accumulated text
    ///    is merged into the supplement and written. A sweep that is cut short
    ///    at page 90 leaves 9,000 fresh element sets on disk, not nothing.
    ///  * **It gives up when told to.** A 429, 503 or 508 is the service
    ///    saying "not now". The sweep stops there, keeps what it has, and lets
    ///    the ordinary failure backoff decide when to come back. It does not
    ///    retry the page, and it does not finish the loop.
    ///  * **It is bounded.** `maximumPages` and the page-size cap put a hard
    ///    ceiling on the traffic a single sweep can generate.
    private func refreshPaged(_ source: PagedSource) async throws -> Bool {
        guard let destination = supplementFileURL else { return false }

        var pending: [String] = []
        var fetchedElementSets = 0
        var pagesFetched = 0
        var changedOnDisk = false
        var rateLimited = false

        func flush() throws {
            guard !pending.isEmpty else { return }
            let existing = (try? String(contentsOf: destination, encoding: .utf8)) ?? ""
            let merged = Self.mergeElementSetText(
                supplement: pending.joined(), onto: existing
            )
            pending.removeAll(keepingCapacity: true)
            guard merged != existing else { return }
            try write(merged, to: destination)
            changedOnDisk = true
        }

        pageLoop: for page in 1...source.maximumPages {
            if Task.isCancelled { break }
            if page > 1 {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.pageRequestInterval * 1_000_000_000)
                )
            }
            let text: String
            do {
                text = try await fetchPage(source, page: page)
            } catch RefreshError.rateLimited {
                rateLimited = true
                break pageLoop
            } catch {
                // A single failed page mid-sweep is not worth abandoning the
                // whole thing over, but a run of them is: the service has gone
                // away and every further request is noise.
                break pageLoop
            }
            let count = TwoLineElement.parseCatalog(text).count
            if count == 0 { break pageLoop }  // past the end of the collection
            pending.append(text)
            fetchedElementSets += count
            pagesFetched = page
            if page % Self.pageFlushInterval == 0 { try flush() }
        }
        try flush()

        if rateLimited {
            Self.logger.notice(
                "\(source.name) rate-limited after \(pagesFetched) pages; keeping \(fetchedElementSets) element sets"
            )
        } else {
            Self.logger.info(
                "\(source.name) bulk sweep fetched \(fetchedElementSets) element sets over \(pagesFetched) pages"
            )
        }
        guard fetchedElementSets >= source.minimumElementSets || changedOnDisk else {
            throw RefreshError.unexpectedResponse
        }
        return changedOnDisk
    }

    /// One page of a paged source, as three-line TLE text.
    private func fetchPage(_ source: PagedSource, page: Int) async throws -> String {
        var components = URLComponents(url: source.baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "page-size", value: String(source.pageSize)),
            URLQueryItem(name: "page", value: String(page)),
        ]
        guard let url = components?.url else { throw RefreshError.unexpectedResponse }
        let data = try await fetchData(url, timeout: 30)
        return try Self.tleText(fromCollectionJSON: data)
    }

    /// The mirror's collection endpoint answers a Hydra document:
    /// `{"totalItems": 25706, "member": [{"satelliteId": …, "name": …, "line1": …, "line2": …}]}`.
    /// The per-object endpoint answers one of those members directly, which is
    /// why both share `member(_:)` below.
    static func tleText(fromCollectionJSON data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let members = object["member"] as? [[String: Any]] else {
            throw RefreshError.undecodableResponse
        }
        var lines: [String] = []
        lines.reserveCapacity(members.count * 3)
        for entry in members {
            guard let line1 = entry["line1"] as? String,
                  let line2 = entry["line2"] as? String else { continue }
            let name = (entry["name"] as? String)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            lines.append(name)
            lines.append(line1)
            lines.append(line2)
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// Fetches a few named objects one at a time and folds them into the
    /// supplement file.
    ///
    /// Merged, never written over the top: the supplement may already hold
    /// SatNOGS or AMSAT elements for objects this sweep does not cover, and
    /// `overlay` keeps whichever set is newer for each object. Returns true
    /// when the file on disk actually changed.
    ///
    /// Stops early and quietly on the first non-200 response. A mirror that
    /// starts refusing requests is telling us to go away, and the correct
    /// response is to go away rather than to finish the loop.
    @discardableResult
    func refreshTargeted(catalogNumbers: [Int]) async -> Bool {
        guard let destination = supplementFileURL, !catalogNumbers.isEmpty else { return false }

        var fetched: [String] = []
        for (index, number) in catalogNumbers.prefix(Self.maximumTargetedRequests).enumerated() {
            if index > 0 {
                try? await Task.sleep(nanoseconds: UInt64(Self.targetedRequestInterval * 1_000_000_000))
            }
            guard let text = try? await fetchTargeted(catalogNumber: number) else { break }
            fetched.append(text)
        }
        guard !fetched.isEmpty else { return false }

        let existingText = (try? String(contentsOf: destination, encoding: .utf8)) ?? ""
        let text = Self.mergeElementSetText(
            supplement: fetched.joined(), onto: existingText
        )
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let existing = try? String(contentsOf: destination, encoding: .utf8)
            guard existing != text else { return false }
            try Data(text.utf8).write(to: destination, options: .atomic)
        } catch {
            return false
        }

        refreshStatus.lastSuccess = Date()
        refreshStatus.lastSuccessfulSource = Self.targetedSourceName
        Self.logger.info(
            "Targeted refresh updated \(fetched.count) notable element sets from \(Self.targetedSourceName)"
        )
        return true
    }

    /// One object's element set, as three-line TLE text.
    private func fetchTargeted(catalogNumber: Int) async throws -> String {
        let url = Self.targetedSourceBaseURL.appendingPathComponent(String(catalogNumber))
        let data = try await fetchData(url, timeout: 20)
        return try Self.tleText(fromTargetedJSON: data)
    }

    /// One HTTP GET, with the app's User-Agent, and a rate limit told apart
    /// from an ordinary failure.
    ///
    /// The distinction matters because the two call for opposite responses. An
    /// ordinary failure is worth retrying against the next source; a rate
    /// limit means every further request to *this* host will fail too and the
    /// polite thing is to stop asking. The mirror answers 508 ("resource limit
    /// is reached") rather than 429 when it is under load, and shared hosts
    /// commonly use 503, so all three are treated the same way.
    private func fetchData(_ url: URL, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RefreshError.unexpectedResponse
        }
        if Self.rateLimitStatusCodes.contains(http.statusCode) {
            throw RefreshError.rateLimited
        }
        guard http.statusCode == 200 else { throw RefreshError.unexpectedResponse }
        return data
    }

    static let rateLimitStatusCodes: Set<Int> = [429, 503, 508]

    /// The lookup serves a single object as
    /// `{"satelliteId": 25544, "name": "ISS (ZARYA)", "line1": "1 …", "line2": "2 …"}`.
    static func tleText(fromTargetedJSON data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let line1 = object["line1"] as? String,
              let line2 = object["line2"] as? String else {
            throw RefreshError.undecodableResponse
        }
        let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return "\(name)\n\(line1)\n\(line2)\n"
    }

    /// Merges one element-set *file* over another, newest-epoch-wins.
    ///
    /// Exactly the rule `overlay` applies, but carried out on the raw
    /// three-line text rather than on parsed `TwoLineElement` values.
    ///
    /// Text, because `TwoLineElement` keeps the *decoded* fields and not the
    /// lines it decoded them from, so a parse/re-emit round trip would have to
    /// reconstruct — and re-checksum — every record. Rewriting element sets
    /// from our own formatter is a great way to introduce a subtle field-width
    /// bug into the one thing in this app that has to be byte-exact. The lines
    /// arrive from the source correct; they are stored exactly as they arrived.
    ///
    /// `TwoLineElement.parse` is still used, but only to *read* the catalogue
    /// number and epoch that decide which record wins.
    static func mergeElementSetText(supplement: String, onto base: String) -> String {
        /// One record as it appeared: name line, line 1, line 2.
        struct Record {
            var lines: [String]
            var epochJulianDay: Double
        }

        func records(in text: String) -> [(number: Int, record: Record)] {
            var out: [(Int, Record)] = []
            var pendingName: String?
            var pendingLine1: String?
            text.enumerateLines { rawLine, _ in
                let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
                if line.hasPrefix("1 ") {
                    pendingLine1 = line
                } else if line.hasPrefix("2 "), let line1 = pendingLine1 {
                    if let element = TwoLineElement.parse(
                        name: pendingName, line1: line1, line2: line
                    ) {
                        out.append((
                            element.catalogNumber,
                            Record(
                                lines: [pendingName ?? element.name, line1, line],
                                epochJulianDay: element.epochJulianDay
                            )
                        ))
                    }
                    pendingLine1 = nil
                    pendingName = nil
                } else {
                    pendingName = line.trimmingCharacters(in: .whitespaces)
                }
            }
            return out
        }

        var order: [Int] = []
        var byNumber: [Int: Record] = [:]
        for (number, record) in records(in: base) {
            if byNumber[number] == nil { order.append(number) }
            byNumber[number] = record
        }
        for (number, record) in records(in: supplement) {
            if let existing = byNumber[number] {
                if record.epochJulianDay > existing.epochJulianDay {
                    byNumber[number] = record
                }
            } else {
                order.append(number)
                byNumber[number] = record
            }
        }

        var lines: [String] = []
        lines.reserveCapacity(order.count * 3)
        for number in order {
            guard let record = byNumber[number] else { continue }
            lines.append(contentsOf: record.lines)
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// One source's body, already converted to TLE text.
    private func fetch(_ source: Source) async throws -> String {
        let data = try await fetchData(source.url, timeout: 30)
        guard let body = String(data: data, encoding: .utf8) else {
            throw RefreshError.undecodableResponse
        }
        switch source.format {
        case .tleText:
            return body
        case .satnogsJSON:
            return try Self.tleText(fromSatnogsJSON: data)
        }
    }

    /// SatNOGS serves `[{"tle0": "0 ISS (ZARYA)", "tle1": "1 25544U…", …}]`.
    /// The name line carries a leading "0 " in the NASA convention, which the
    /// three-line parser here does not expect, so it is stripped.
    static func tleText(fromSatnogsJSON data: Data) throws -> String {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw RefreshError.undecodableResponse
        }
        var lines: [String] = []
        lines.reserveCapacity(array.count * 3)
        for entry in array {
            guard let line1 = entry["tle1"] as? String,
                  let line2 = entry["tle2"] as? String else { continue }
            var name = (entry["tle0"] as? String) ?? ""
            if name.hasPrefix("0 ") { name.removeFirst(2) }
            lines.append(name.trimmingCharacters(in: .whitespaces))
            lines.append(line1)
            lines.append(line2)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    enum RefreshError: LocalizedError {
        case unexpectedResponse
        case undecodableResponse
        case rateLimited

        var errorDescription: String? {
            switch self {
            case .unexpectedResponse: return "unexpected response"
            case .undecodableResponse: return "response could not be read as element sets"
            case .rateLimited: return "the source asked us to slow down"
            }
        }
    }

    /// Drops the in-memory catalogue so the next load re-reads from disk.
    /// Used after a successful refresh.
    func invalidate() {
        cachedSatellites = nil
    }

    /// `~/Library/Application Support/Astronomy` — inside the app's container
    /// when sandboxed, which is where this app's files actually live:
    /// `~/Library/Containers/com.shubhisrivastava.Astronomy/Data/Library/Application Support/Astronomy/`.
    static var defaultSupportDirectory: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return base.appendingPathComponent("Astronomy", isDirectory: true)
    }

    var cacheFileURL: URL? {
        supportDirectory?.appendingPathComponent("satellites.txt")
    }

    /// Partial, fresher element sets from a fallback source, overlaid onto
    /// whatever the full catalogue is.
    var supplementFileURL: URL? {
        supportDirectory?.appendingPathComponent("satellites-supplement.txt")
    }
}
