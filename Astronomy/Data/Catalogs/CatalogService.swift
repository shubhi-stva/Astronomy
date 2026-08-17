//
//  CatalogService.swift
//  Astronomy
//
//  Loads the bundled star and constellation-line catalogs asynchronously
//  off the main thread using Swift Concurrency, decoding once and handing
//  back immutable value types.
//
//  See DATA_SOURCES.md for exact provenance of stars.json / constellations.json.
//

import Foundation

enum CatalogServiceError: Error {
    case resourceNotFound(String)
}

actor CatalogService {

    static let shared = CatalogService()

    private var cachedStars: [Star]?
    private var cachedConstellationLines: [ConstellationLineSegment]?
    private var cachedConstellations: [Constellation]?

    /// Loads (and caches) the constellation name/centre table used for labels.
    func loadConstellations() async throws -> [Constellation] {
        if let cachedConstellations { return cachedConstellations }
        let items: [Constellation] = try Self.decodeBundledJSON(named: "constellation_names")
        cachedConstellations = items
        return items
    }

    /// Loads (and caches) the bundled star catalog. Decoding happens on this
    /// actor's background executor, not the main thread.
    func loadStars() async throws -> [Star] {
        if let cachedStars { return cachedStars }
        let stars: [Star] = try Self.decodeBundledJSON(named: "stars")
        cachedStars = stars
        return stars
    }

    /// Loads (and caches) the bundled constellation line segments.
    func loadConstellationLines() async throws -> [ConstellationLineSegment] {
        if let cachedConstellationLines { return cachedConstellationLines }
        let lines: [ConstellationLineSegment] = try Self.decodeBundledJSON(named: "constellations")
        cachedConstellationLines = lines
        return lines
    }

    private static func decodeBundledJSON<T: Decodable>(named name: String) throws -> T {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json") else {
            throw CatalogServiceError.resourceNotFound(name)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
