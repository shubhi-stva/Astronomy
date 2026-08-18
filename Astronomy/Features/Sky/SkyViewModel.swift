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
    /// Built off the main actor alongside the catalogue; see `StarIndex`.
    private(set) var starIndex: StarIndex?
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
    private(set) var deepSkyObjects: [DeepSkyObject] = []

    // MARK: Satellites

    private let satelliteTracker = SatelliteTracker()
    /// Latest propagation tick. The renderer extrapolates from this every
    /// frame; see `SatelliteTracker`.
    private(set) var satelliteSnapshot: SatelliteSnapshot = .empty
    private(set) var satelliteDescriptors: [SatelliteDescriptor] = []
    /// Duration of the last propagation pass, exposed for the performance note
    /// in the time bar's tooltip and for tests.
    private(set) var lastSatellitePropagationSeconds: TimeInterval = 0

    /// Master switch for the satellite layer.
    var satellitesEnabled = true
    /// Reveals the whole catalogue rather than only what is genuinely visible.
    var showAllSatellites = false

    private nonisolated(unsafe) var ephemerisRefreshTask: Task<Void, Never>?
    private nonisolated(unsafe) var satelliteTask: Task<Void, Never>?

    init() {
        Task { await loadCatalog() }
        startEphemerisRefresh()
        startSatelliteTracking()
    }

    deinit {
        ephemerisRefreshTask?.cancel()
        satelliteTask?.cancel()
    }

    /// Loads the satellite catalogue, then propagates it forever at the
    /// tracker's tick rate, on its own detached task. A daily CelesTrak
    /// refresh is kicked off once, after the first tick, so a slow network
    /// never delays the first satellites appearing.
    ///
    /// Detached deliberately. A plain `Task { }` created here inherits the
    /// view model's `@MainActor` isolation, which means the loop body, the
    /// `Task.sleep` resumption and the publish all queue for main-actor time —
    /// and the main actor is the busiest thread in the app, driving geometry
    /// for every frame at up to 120 Hz. The propagation loop lost that race
    /// badly: ticks meant to land 0.4 s apart were arriving tens of seconds
    /// apart, so the extrapolation ran out (it is clamped to a couple of
    /// seconds, on purpose) and satellites sat still until the next snapshot
    /// finally landed and teleported them.
    ///
    /// Detaching puts the loop and its sleeps on the global executor. The only
    /// main-actor work left is reading the frame inputs and publishing the
    /// result — two short hops per tick instead of the whole loop.
    private func startSatelliteTracking() {
        satelliteTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.satelliteTracker.load()
            await self.updateSatelliteDescriptors()

            var didAttemptRefresh = false
            while !Task.isCancelled {
                let tickStart = ContinuousClock.now

                guard let inputs = await self.satellitePropagationInputs() else { return }
                let snapshot = await self.satelliteTracker.propagate(
                    julianDay: inputs.julianDay,
                    observer: inputs.observer,
                    sunEquatorial: inputs.sunEquatorial,
                    sunDistanceKilometres: inputs.sunDistanceKilometres
                )
                await self.publish(snapshot: snapshot)

                if !didAttemptRefresh {
                    didAttemptRefresh = true
                    await self.refreshSatelliteElements()
                }

                // Sleep for whatever is left of the tick rather than a fixed
                // interval, so a slow pass shortens the wait instead of adding
                // to it and letting the cadence drift.
                let spent = ContinuousClock.now - tickStart
                let remaining = .seconds(SatelliteTracker.tickInterval) - spent
                if remaining > .zero {
                    try? await Task.sleep(for: remaining)
                } else {
                    await Task.yield()
                }
            }
        }
    }

    /// Everything a propagation pass needs from main-actor state, read in one
    /// short hop so the detached loop touches the main actor as little as
    /// possible.
    private func satellitePropagationInputs() -> (
        julianDay: Double,
        observer: GeographicLocation,
        sunEquatorial: EquatorialCoordinate,
        sunDistanceKilometres: Double
    )? {
        guard satellitesEnabled else { return nil }
        let jd = time.julianDay
        let sunEquatorial = solarSystemObjects.first { $0.kind == .sun }?.equatorial
            ?? SunPosition.equatorialCoordinate(julianDay: jd)
        let sunDistance = SunPosition.radiusVectorAU(julianDay: jd)
            * AstronomicalConstants.astronomicalUnitKilometres
        return (jd, location.currentLocation, sunEquatorial, sunDistance)
    }

    /// Publishes a finished snapshot. The visible-count reduction runs here
    /// because it is a scan of 16,000 samples and has no business on the
    /// render path.
    private func publish(snapshot: SatelliteSnapshot) {
        satelliteSnapshot = snapshot
        visibleSatelliteCount = snapshot.samples.reduce(into: 0) { count, sample in
            if sample.illumination.isSunlit && sample.altitudeDegreesAtSnapshot > 0 { count += 1 }
        }
        if snapshot.propagationDuration > 0 {
            lastSatellitePropagationSeconds = snapshot.propagationDuration
        }
    }

    /// How many satellites are genuinely visible right now: sunlit and above
    /// the horizon. This is the count the satellite control shows, and it is
    /// also exactly the default render set's size, which is the point.
    private(set) var visibleSatelliteCount = 0

    /// Lower-cased satellite names, parallel to `satelliteDescriptors`.
    private var satelliteSearchNames: [String] = []

    private func updateSatelliteDescriptors() async {
        satelliteDescriptors = await satelliteTracker.descriptors
        // Lower-cased once here rather than sixteen thousand times per
        // keystroke in `satelliteMatches`.
        satelliteSearchNames = satelliteDescriptors.map { $0.name.lowercased() }
    }

    /// Fetches fresh element sets, at most once a day (the interval is enforced
    /// by the catalogue service). A failure is silent by design: the bundled
    /// snapshot keeps working, which is the whole point of bundling it.
    private func refreshSatelliteElements() async {
        let didRefresh = await SatelliteCatalogService.shared.refreshIfStale()
        guard didRefresh else { return }
        await satelliteTracker.reload()
        await updateSatelliteDescriptors()
    }

    private func loadCatalog() async {
        do {
            // All of this runs on the CatalogService actor's executor, never
            // on the main actor: the 8.8 MB decode and the spatial-index build
            // happen while `isLoadingCatalog` is still true and the UI shows
            // its loading state. Only the assignments below touch @MainActor.
            async let indexResult = CatalogService.shared.loadStarIndex()
            async let linesResult = CatalogService.shared.loadConstellationLines()
            async let namesResult = CatalogService.shared.loadConstellations()
            async let deepSkyResult = CatalogService.shared.loadDeepSkyObjects()
            let (loadedIndex, loadedLines, loadedNames) = try await (indexResult, linesResult, namesResult)
            let loadedDeepSky = try await deepSkyResult
            let loadedStars = try await CatalogService.shared.loadStars()
            self.starIndex = loadedIndex
            self.stars = loadedStars
            self.starsByID = Dictionary(uniqueKeysWithValues: loadedStars.map { ($0.id, $0) })
            self.constellationLines = loadedLines
            self.constellations = loadedNames
            self.deepSkyObjects = loadedDeepSky
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
        refreshSelectedSatellite()

        // Sample the clock exactly once per frame. `time.julianDay` is
        // continuous — it reads the system clock on every access — so calling
        // it repeatedly would build one frame from several slightly different
        // instants. Physically that difference is microseconds and harmless,
        // but a frame should be a single moment.
        let frameJulianDay = time.julianDay

        let sun = solarSystemObjects.first { $0.kind == .sun }
        let moon = solarSystemObjects.first { $0.kind == .moon }
        let sunHorizontal = sun.map {
            CoordinateTransformService.horizontal(
                from: $0.equatorial,
                observer: location.currentLocation,
                julianDay: frameJulianDay
            )
        }

        // Keep ephemeris reasonably fresh even between the 30s refresh ticks
        // (time advances continuously via TimeController).
        var frame = SkyFrameData(
            stars: stars,
            solarSystemObjects: solarSystemObjects,
            constellationLines: constellationLines,
            constellations: constellations,
            deepSkyObjects: deepSkyObjects,
            starsByID: starsByID,
            starIndex: starIndex,
            observerLocation: location.currentLocation,
            julianDay: frameJulianDay,
            cameraCenter: camera.centerHorizontal,
            cameraFieldOfViewDegrees: camera.fieldOfViewDegrees,
            viewportSize: viewportSize,
            sunHorizontal: sunHorizontal,
            sunEquatorial: sun?.equatorial,
            moonEquatorial: moon?.equatorial,
            selectedObjectID: selectedObject?.id
        )
        frame.satelliteSnapshot = satelliteSnapshot
        frame.satelliteDescriptors = satelliteDescriptors
        frame.satellitesEnabled = satellitesEnabled
        frame.showAllSatellites = showAllSatellites
        return frame
    }

    /// Keeps the info panel live for a selected satellite.
    ///
    /// Every other kind of object is effectively static over a session, so its
    /// panel can be a snapshot taken at selection time. A satellite crosses the
    /// sky in minutes: its altitude, azimuth and range are all changing while
    /// you look at them, and a frozen panel would be worse than no panel.
    private func refreshSelectedSatellite() {
        guard let selected = selectedObject, selected.kind == .satellite else { return }
        guard let details = selected.satelliteDetails else { return }
        guard let sample = satelliteSnapshot.sample(descriptorIndex: details.descriptorIndex),
              sample.catalogNumber == details.catalogNumber,
              sample.index < satelliteDescriptors.count else { return }

        let jd = time.julianDay
        let elapsed = min(2.0, max(-2.0, (jd - satelliteSnapshot.julianDay) * 86_400.0))
        let look = TopocentricTransform.lookAngles(
            satellitePositionTEME: sample.position + sample.velocity * elapsed,
            observer: location.currentLocation,
            julianDay: jd
        )
        selectedObject = SkyGeometryBuilder.celestialObject(
            descriptor: satelliteDescriptors[sample.index],
            descriptorIndex: sample.index,
            look: look,
            illumination: sample.illumination,
            observer: location.currentLocation,
            julianDay: jd
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

        // Deep-sky objects match on either spelling: the common name
        // ("Andromeda Galaxy", "Pleiades") or the catalogue designation
        // ("M31", "NGC 7000"). Designations are compared with whitespace
        // removed so "NGC7000" and "NGC 7000" both hit.
        let condensedQuery = lowered.replacingOccurrences(of: " ", with: "")
        let deepSkyMatches = deepSkyObjects
            .filter { object in
                if let name = object.name?.lowercased(), name.contains(lowered) { return true }
                let designation = object.catalogName.lowercased()
                    .replacingOccurrences(of: " ", with: "")
                return designation.contains(condensedQuery)
                    || object.id.lowercased().contains(condensedQuery)
            }
            .sorted { $0.magnitude < $1.magnitude }
            .prefix(20)
            .map { $0.asCelestialObject }

        results.append(contentsOf: deepSkyMatches)
        results.append(contentsOf: satelliteMatches(lowered: lowered, query: query))
        searchResults = results
    }

    /// Satellites match on name or on NORAD catalog number, so both "ISS" and
    /// "25544" find the station.
    ///
    /// Matches are built from the *snapshot*, not the catalogue, so a result is
    /// only offered when there is a real current position behind it — searching
    /// up an object the propagator has rejected would hand back a target the
    /// camera could not fly to.
    private func satelliteMatches(lowered: String, query: String) -> [CelestialObject] {
        guard satellitesEnabled, !satelliteDescriptors.isEmpty else { return [] }
        // A single character would match most of a sixteen-thousand-object
        // catalogue, which is neither useful nor cheap.
        guard lowered.count >= 2 || Int(query) != nil else { return [] }
        let queryNumber = Int(query)
        let jd = time.julianDay
        let observer = location.currentLocation
        let elapsed = min(2.0, max(-2.0, (jd - satelliteSnapshot.julianDay) * 86_400.0))

        var matches: [CelestialObject] = []
        for sample in satelliteSnapshot.samples {
            guard sample.index < satelliteDescriptors.count else { continue }
            let descriptor = satelliteDescriptors[sample.index]
            let numberMatches = queryNumber != nil && descriptor.catalogNumber == queryNumber
            let nameMatches = sample.index < satelliteSearchNames.count
                && satelliteSearchNames[sample.index].contains(lowered)
            guard nameMatches || numberMatches else { continue }

            let look = TopocentricTransform.lookAngles(
                satellitePositionTEME: sample.position + sample.velocity * elapsed,
                observer: observer, julianDay: jd
            )
            matches.append(
                SkyGeometryBuilder.celestialObject(
                    descriptor: descriptor, descriptorIndex: sample.index, look: look,
                    illumination: sample.illumination,
                    observer: observer, julianDay: jd
                )
            )
            if matches.count >= 40 { break }
        }
        // Notable objects and the ones actually up in the sky first: with 16,000
        // candidates the ordering of a substring match is most of its value.
        return matches.sorted { a, b in
            let aAlt = a.satelliteDetails?.horizontal.altitudeDegrees ?? -90
            let bAlt = b.satelliteDetails?.horizontal.altitudeDegrees ?? -90
            if (aAlt > 0) != (bAlt > 0) { return aAlt > 0 }
            return a.name.count < b.name.count
        }
        .prefix(12)
        .map { $0 }
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
