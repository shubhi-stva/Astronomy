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

    /// These services ask clients not to poll aggressively and to identify
    /// themselves. Both are honoured: this User-Agent is descriptive, and
    /// `minimumRefreshInterval` is a hard floor of one day between *successful*
    /// refreshes.
    static let userAgent = "Astronomy-macOS-Planetarium/1.0 (satellite tracking; TLE refresh once per day)"

    /// Element sets are re-issued at most a few times a day and the app's
    /// accuracy is limited by other things long before it is limited by a few
    /// hours of element age. One day is both polite and sufficient.
    static let minimumRefreshInterval: TimeInterval = 24 * 60 * 60

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
        if let cacheURL = Self.cacheFileURL,
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
        guard let url = Self.supplementFileURL,
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
        guard let age = cacheAge() else { return 0 }
        return max(0, Self.minimumRefreshInterval - age)
    }

    /// Seconds since the full cache was written, or nil if there is no cache.
    private func cacheAge() -> TimeInterval? {
        guard let cacheURL = Self.cacheFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(modified)
    }

    /// Fetches fresh element sets if the cache is older than a day, trying each
    /// source in turn. Returns true when something on disk actually changed.
    ///
    /// Never throws: a network failure must not be able to break the sky.
    @discardableResult
    func refreshIfStale() async -> Bool {
        if consecutiveFailures == 0, let age = cacheAge(), age < Self.minimumRefreshInterval {
            return false
        }
        return await refresh()
    }

    /// Unconditional refresh attempt across every source, best first.
    ///
    /// Stops at the first source that yields a plausible element-set file. A
    /// complete source replaces the cache; a partial one is written to the
    /// supplement file and overlaid at load time, so falling back never costs
    /// the user 14,000 objects.
    @discardableResult
    func refresh() async -> Bool {
        refreshStatus.lastAttempt = Date()
        var failures: [String] = []

        for source in Self.sources {
            do {
                let text = try await fetch(source)
                let elements = TwoLineElement.parseCatalog(text)
                // Sanity-check before overwriting a working cache: CelesTrak
                // serves an HTML error page on rate limiting, and a 300-byte
                // "slow down" must not replace 16,000 good element sets.
                guard elements.count >= source.minimumElementSets else {
                    failures.append("\(source.name): response did not look like an element-set file")
                    continue
                }
                let destination = source.isComplete ? Self.cacheFileURL : Self.supplementFileURL
                guard let destination else {
                    failures.append("\(source.name): no writable cache location")
                    continue
                }
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(text.utf8).write(to: destination, options: .atomic)

                consecutiveFailures = 0
                lastRefreshError = nil
                refreshStatus.consecutiveFailures = 0
                refreshStatus.lastSuccess = Date()
                refreshStatus.lastSuccessfulSource = source.name
                Self.logger.info(
                    "Refreshed \(elements.count) satellite element sets from \(source.name)"
                )
                return true
            } catch {
                failures.append("\(source.name): \(error.localizedDescription)")
            }
        }

        consecutiveFailures += 1
        refreshStatus.consecutiveFailures = consecutiveFailures
        lastRefreshError = failures.first ?? "no element-set source could be reached"
        Self.logger.notice(
            "Satellite refresh failed, keeping existing elements: \(failures.joined(separator: "; "))"
        )
        return false
    }

    /// One source's body, already converted to TLE text.
    private func fetch(_ source: Source) async throws -> String {
        var request = URLRequest(url: source.url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RefreshError.unexpectedResponse
        }
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

        var errorDescription: String? {
            switch self {
            case .unexpectedResponse: return "unexpected response"
            case .undecodableResponse: return "response could not be read as element sets"
            }
        }
    }

    /// Drops the in-memory catalogue so the next load re-reads from disk.
    /// Used after a successful refresh.
    func invalidate() {
        cachedSatellites = nil
    }

    private static var supportDirectory: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return base.appendingPathComponent("Astronomy", isDirectory: true)
    }

    private static var cacheFileURL: URL? {
        supportDirectory?.appendingPathComponent("satellites.txt")
    }

    /// Partial, fresher element sets from a fallback source, overlaid onto
    /// whatever the full catalogue is.
    private static var supplementFileURL: URL? {
        supportDirectory?.appendingPathComponent("satellites-supplement.txt")
    }
}
