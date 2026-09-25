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
    private var cachedStarIndex: StarIndex?
    private var cachedStarSearchIndex: StarSearchIndex?
    private var cachedConstellationLines: [ConstellationLineSegment]?
    private var cachedConstellations: [Constellation]?
    private var cachedDeepSky: [DeepSkyObject]?
    private var cachedBoundaries: ConstellationBoundaries?
    private var cachedDeepSkyIndex: DeepSkyIndex?
    private var cachedFigureIndex: ConstellationFigureIndex?

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

    /// Loads (and caches) the spatial index over the star catalogue.
    ///
    /// Built here, on the actor's background executor, because it is the one
    /// place that already owns the decoded catalogue and is already off the
    /// main thread. Cost is a single bucketing pass plus 2,592 bounding-cone
    /// computations — small next to decoding 8.8 MB of JSON, and paid once.
    func loadStarIndex() async throws -> StarIndex {
        if let cachedStarIndex { return cachedStarIndex }
        let index = StarIndex(stars: try await loadStars())
        cachedStarIndex = index
        return index
    }

    /// Loads (and caches) the designation index used by search.
    ///
    /// Built here for the same reason `loadStarIndex` is: this actor already
    /// owns the decoded catalogue and is already off the main thread. The
    /// build is one pass over 83,479 stars plus about 26,000 short string
    /// normalisations, which is small next to the JSON decode it follows.
    func loadStarSearchIndex() async throws -> StarSearchIndex {
        if let cachedStarSearchIndex { return cachedStarSearchIndex }
        let index = StarSearchIndex(stars: try await loadStars())
        cachedStarSearchIndex = index
        return index
    }

    /// Loads (and caches) the bundled deep-sky catalogue (OpenNGC-derived;
    /// see DATA_SOURCES.md). Dark nebulae are dropped here rather than at
    /// render time: they are absorption features with no light of their own,
    /// so there is nothing sensible for the renderer or search to do with one.
    func loadDeepSkyObjects() async throws -> [DeepSkyObject] {
        if let cachedDeepSky { return cachedDeepSky }
        let all: [DeepSkyObject] = try Self.decodeBundledJSON(named: "deepsky")
        let items = all.filter { $0.type.isRenderable }
        cachedDeepSky = items
        return items
    }

    /// Loads (and caches) the deep-sky catalogue with its cull index. See
    /// `DeepSkyIndex`.
    func loadDeepSkyIndex() async throws -> DeepSkyIndex {
        if let cachedDeepSkyIndex { return cachedDeepSkyIndex }
        let index = DeepSkyIndex(objects: try await loadDeepSkyObjects())
        cachedDeepSkyIndex = index
        return index
    }

    /// Loads (and caches) the constellation figures with their endpoints
    /// already joined against the star catalogue. See
    /// `ConstellationFigureIndex` for the per-frame cost this removes.
    func loadConstellationFigures() async throws -> ConstellationFigureIndex {
        if let cachedFigureIndex { return cachedFigureIndex }
        let stars = try await loadStars()
        let byID = Dictionary(stars.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let index = ConstellationFigureIndex(
            segments: try await loadConstellationLines(), starsByID: byID
        )
        cachedFigureIndex = index
        return index
    }

    /// Loads (and caches) the IAU constellation boundaries. See
    /// `ConstellationBoundary`.
    func loadConstellationBoundaries() async throws -> ConstellationBoundaries {
        if let cachedBoundaries { return cachedBoundaries }
        let edges: [ConstellationBoundaryEdge] =
            try Self.decodeBundledJSON(named: "constellation_boundaries")
        let boundaries = ConstellationBoundaries(edges: edges)
        cachedBoundaries = boundaries
        return boundaries
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
