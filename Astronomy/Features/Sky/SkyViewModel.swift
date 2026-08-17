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
    var labels: [SkyLabel] = []

    private(set) var constellations: [Constellation] = []

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
            async let namesResult = CatalogService.shared.loadConstellations()
            let (loadedStars, loadedLines, loadedNames) = try await (starsResult, linesResult, namesResult)
            self.stars = loadedStars
            self.starsByID = Dictionary(uniqueKeysWithValues: loadedStars.map { ($0.id, $0) })
            self.constellationLines = loadedLines
            self.constellations = loadedNames
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
        // Advance camera momentum/focus-flight in lockstep with the frame the
        // renderer is about to draw, so panning and flights stay smooth at
        // whatever refresh rate the display link is running.
        camera.tick()

        let sun = solarSystemObjects.first { $0.kind == .sun }
        let moon = solarSystemObjects.first { $0.kind == .moon }
        let sunHorizontal = sun.map {
            CoordinateTransformService.horizontal(
                from: $0.equatorial,
                observer: location.currentLocation,
                julianDay: time.julianDay
            )
        }

        // Keep ephemeris reasonably fresh even between the 30s refresh ticks
        // (time keeps advancing every second via TimeController).
        return SkyFrameData(
            stars: stars,
            solarSystemObjects: solarSystemObjects,
            constellationLines: constellationLines,
            constellations: constellations,
            starsByID: starsByID,
            observerLocation: location.currentLocation,
            julianDay: time.julianDay,
            cameraCenter: camera.centerHorizontal,
            cameraFieldOfViewDegrees: camera.fieldOfViewDegrees,
            viewportSize: viewportSize,
            sunHorizontal: sunHorizontal,
            sunEquatorial: sun?.equatorial,
            moonEquatorial: moon?.equatorial,
            selectedObjectID: selectedObject?.id
        )
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

    /// Recenters the camera on an object and selects it, instantly (used by
    /// search, where the object may currently be off-screen).
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

    /// Smoothly flies the camera to an object (double-click), zooming in a
    /// little if the current field of view is very wide.
    func flyToFocus(on object: CelestialObject?) {
        guard let object else { return }
        let horizontal = CoordinateTransformService.horizontal(
            from: object.equatorial,
            observer: location.currentLocation,
            julianDay: time.julianDay
        )
        let targetFOV = min(camera.fieldOfViewDegrees, 30)
        camera.flyTo(horizontal, fieldOfViewDegrees: targetFOV)
        selectedObject = object
    }

    // MARK: - Trackpad/pinch handlers

    func handlePanEnded(velocityX: Double, velocityY: Double, viewportSize: CGSize) {
        if velocityX == 0 && velocityY == 0 {
            camera.stopMomentum()
        } else {
            camera.beginMomentum(velocityX: velocityX, velocityY: velocityY, viewportSize: viewportSize)
        }
    }

    func handleZoomFactor(_ factor: Double) {
        camera.applyZoomFactor(factor)
    }
}
