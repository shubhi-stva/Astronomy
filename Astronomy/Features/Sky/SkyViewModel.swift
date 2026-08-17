//
//  SkyViewModel.swift
//  Astronomy
//
//  Central state for the Sky feature: owns the camera, wires together
//  TimeController + LocationService + the catalog, and produces the
//  per-frame snapshot the Metal renderer consumes. Handles search and
//  selection.
//

import CoreGraphics
import Foundation
import Observation
import simd

@Observable
@MainActor
final class SkyViewModel {

    let time = TimeController()
    let camera = Camera()
    let location = LocationService()

    private(set) var stars: [Star] = []
    private(set) var starsByID: [Int: Star] = [:]
    private(set) var constellationLines: [ConstellationLineSegment] = []
    private(set) var isLoadingCatalog = true
    private(set) var loadError: String?

    private(set) var solarSystemObjects: [CelestialObject] = []

    var selectedObject: CelestialObject?
    var viewportSize: CGSize = .zero
    var searchText: String = ""
    var searchResults: [CelestialObject] = []

    private nonisolated(unsafe) var ephemerisRefreshTask: Task<Void, Never>?

    init() {
        Task { await loadCatalog() }
        startEphemerisRefresh()
    }

    deinit {
        ephemerisRefreshTask?.cancel()
    }

    private func loadCatalog() async {
        do {
            async let starsResult = CatalogService.shared.loadStars()
            async let linesResult = CatalogService.shared.loadConstellationLines()
            let (loadedStars, loadedLines) = try await (starsResult, linesResult)
            self.stars = loadedStars
            self.starsByID = Dictionary(uniqueKeysWithValues: loadedStars.map { ($0.id, $0) })
            self.constellationLines = loadedLines
        } catch {
            self.loadError = "Failed to load star catalog: \(error.localizedDescription)"
        }
        self.isLoadingCatalog = false
    }

    /// Recomputes Sun/Moon/planet positions periodically since they move
    /// (slowly) as time advances.
    private func startEphemerisRefresh() {
        refreshEphemeris()
        ephemerisRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.refreshEphemeris()
            }
        }
    }

    private func refreshEphemeris() {
        solarSystemObjects = EphemerisService.solarSystemObjects(julianDay: time.julianDay)
    }

    func currentFrameData() -> SkyFrameData {
        // Keep ephemeris reasonably fresh even between the 30s refresh ticks
        // (time keeps advancing every second via TimeController).
        SkyFrameData(
            stars: stars,
            solarSystemObjects: solarSystemObjects,
            constellationLines: constellationLines,
            starsByID: starsByID,
            observerLocation: location.currentLocation,
            julianDay: time.julianDay,
            cameraCenter: camera.centerHorizontal,
            cameraFieldOfViewDegrees: camera.fieldOfViewDegrees,
            viewportSize: viewportSize
        )
    }

    // MARK: - Selection

    func selectNearest(toNDC point: SIMD2<Double>, using renderer: SkyRenderer?) {
        selectedObject = renderer?.nearestObject(toNDC: point)
    }

    // MARK: - Search

    func updateSearchResults() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        let lowered = query.lowercased()

        var results: [CelestialObject] = solarSystemObjects.filter {
            $0.name.lowercased().contains(lowered)
        }

        let starMatches = stars
            .filter { ($0.name?.lowercased().contains(lowered)) ?? false }
            .prefix(20)
            .map { $0.asCelestialObject }

        results.append(contentsOf: starMatches)
        searchResults = results
    }

    /// Recenters the camera on an object and selects it.
    func focus(on object: CelestialObject) {
        let horizontal = CoordinateTransformService.horizontal(
            from: object.equatorial,
            observer: location.currentLocation,
            julianDay: time.julianDay
        )
        camera.center(on: horizontal)
        selectedObject = object
        searchText = ""
        searchResults = []
    }
}
