//
//  SatelliteCatalogService.swift
//  Astronomy
//
//  Loads the satellite element-set catalogue, offline first.
//
//  Order of preference:
//    1. a cached download in Application Support, if it exists and is fresh,
//    2. the snapshot bundled with the app,
//  and separately, in the background and at most once per day, a refresh from
//  CelesTrak that updates the cache for next time.
//
//  The bundle copy is what makes the app work with no network at all, which is
//  the same promise the star catalogue makes. A refresh failure is never
//  allowed to affect the sky: it is logged into `lastRefreshError` for the
//  curious and otherwise ignored.
//
//  Element sets go stale. See DATA_SOURCES.md for the accuracy consequences,
//  which are real and are surfaced in the satellite info panel as an epoch age.
//

import Foundation
import os

actor SatelliteCatalogService {

    static let shared = SatelliteCatalogService()

    /// CelesTrak's "active satellites" group in TLE form. Roughly 16,000
    /// objects, 2.6 MB.
    static let celestrakURL = URL(
        string: "https://celestrak.org/NORAD/elements/gp.php?GROUP=active&FORMAT=tle"
    )!

    /// CelesTrak asks clients not to poll aggressively and to identify
    /// themselves. Both are honoured: this User-Agent is descriptive, and
    /// `minimumRefreshInterval` is a hard floor of one day.
    static let userAgent = "Astronomy-macOS-Planetarium/1.0 (satellite tracking; TLE refresh once per day)"

    /// Element sets are re-issued at most a few times a day and the app's
    /// accuracy is limited by other things long before it is limited by a few
    /// hours of element age. One day is both polite and sufficient.
    static let minimumRefreshInterval: TimeInterval = 24 * 60 * 60

    private static let logger = Logger(subsystem: "Astronomy", category: "satellites")

    private var cachedSatellites: [Satellite]?
    private(set) var lastRefreshError: String?
    /// Provenance of whatever is currently loaded, for diagnostics.
    private(set) var loadedFromCache = false

    // MARK: - Loading

    /// Loads (and caches in memory) the satellite catalogue. Parsing 16,000
    /// element sets and initialising 16,000 SGP4 records happens here, on this
    /// actor's executor, never on the main thread.
    func loadSatellites() async throws -> [Satellite] {
        if let cachedSatellites { return cachedSatellites }

        let text = try loadCatalogText()
        let elements = TwoLineElement.parseCatalog(text)
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

    // MARK: - Refresh

    /// Fetches a fresh catalogue from CelesTrak if the cache is older than a
    /// day, and writes it to Application Support. Returns true when the cache
    /// was actually replaced.
    ///
    /// Never throws: a network failure must not be able to break the sky.
    @discardableResult
    func refreshIfStale() async -> Bool {
        guard let cacheURL = Self.cacheFileURL else { return false }

        if let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
           let modified = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < Self.minimumRefreshInterval {
            return false
        }

        var request = URLRequest(url: Self.celestrakURL)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                lastRefreshError = "CelesTrak returned an unexpected response"
                return false
            }
            // Sanity-check before overwriting a working cache: CelesTrak serves
            // an HTML error page on rate limiting, and a 300-byte "slow down"
            // must not replace 16,000 good element sets.
            guard let text = String(data: data, encoding: .utf8),
                  text.contains("\n1 "),
                  TwoLineElement.parseCatalog(text).count > 1000 else {
                lastRefreshError = "CelesTrak response did not look like an element-set file"
                return false
            }

            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: cacheURL, options: .atomic)
            lastRefreshError = nil
            Self.logger.info("Refreshed satellite element sets from CelesTrak")
            return true
        } catch {
            lastRefreshError = error.localizedDescription
            Self.logger.notice("Satellite refresh failed, keeping existing elements: \(error.localizedDescription)")
            return false
        }
    }

    /// Drops the in-memory catalogue so the next load re-reads from disk.
    /// Used after a successful refresh.
    func invalidate() {
        cachedSatellites = nil
    }

    private static var cacheFileURL: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return base
            .appendingPathComponent("Astronomy", isDirectory: true)
            .appendingPathComponent("satellites.txt")
    }
}
