//
//  SkyViewModel.swift
//  Astronomy
//
//  Central state for the Sky feature: owns the camera, wires together
//  TimeController + LocationService + the catalog, and produces the
//  per-frame snapshot the Metal renderer consumes. Handles search and
//  selection.
//

import AppKit
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
    /// Red-on-black observing mode. Its own object so a view reading the switch
    /// does not thereby depend on everything else here — see `NightVision.swift`.
    let nightVision = NightVisionController()

    private(set) var stars: [Star] = []
    private(set) var starsByID: [Int: Star] = [:]
    /// Built off the main actor alongside the catalogue; see `StarIndex`.
    private(set) var starIndex: StarIndex?
    /// Designation index over the whole catalogue; see `StarSearchIndex`.
    private(set) var starSearchIndex: StarSearchIndex?
    private(set) var constellationLines: [ConstellationLineSegment] = []
    private(set) var isLoadingCatalog = true
    private(set) var loadError: String?

    private(set) var solarSystemObjects: [CelestialObject] = []

    var selectedObject: CelestialObject? {
        didSet {
            guard selectedObject?.id != oldValue?.id else { return }
            // A path belongs to one object. Changing the selection retires it
            // rather than leaving a stale track behind the new selection.
            skyPath = nil
            pathRange = nil
            pathKey = nil
        }
    }
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
    private nonisolated(unsafe) var satelliteRefreshTask: Task<Void, Never>?

    init() {
        Task { await loadCatalog() }
        startEphemerisRefresh()
        startSatelliteTracking()
    }

    deinit {
        ephemerisRefreshTask?.cancel()
        satelliteTask?.cancel()
        satelliteRefreshTask?.cancel()
        calendarTask?.cancel()
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

            var didStartRefreshLoop = false
            while !Task.isCancelled {
                let tickStart = ContinuousClock.now

                guard let inputs = await self.satellitePropagationInputs() else { return }
                let snapshot = await self.satelliteTracker.propagate(
                    julianDay: inputs.julianDay,
                    observer: inputs.observer,
                    sunEquatorial: inputs.sunEquatorial,
                    sunDistanceKilometres: inputs.sunDistanceKilometres,
                    subTickIntervalSeconds: inputs.subTickIntervalSeconds
                )
                // Counted here, off the main actor. It is a scan of sixteen
                // thousand samples and has no business running on the thread
                // that draws frames.
                let visible = snapshot.samples.reduce(into: 0) { count, sample in
                    if sample.illumination.isSunlit && sample.altitudeDegreesAtSnapshot > 0 {
                        count += 1
                    }
                }
                await self.publish(snapshot: snapshot, visibleCount: visible)

                if !didStartRefreshLoop {
                    didStartRefreshLoop = true
                    await self.startSatelliteRefreshLoop()
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
        sunDistanceKilometres: Double,
        subTickIntervalSeconds: Double
    )? {
        guard satellitesEnabled else { return nil }
        let jd = time.julianDay
        let sunEquatorial = solarSystemObjects.first { $0.kind == .sun }?.equatorial
            ?? SunPosition.equatorialCoordinate(julianDay: jd)
        let sunDistance = SunPosition.radiusVectorAU(julianDay: jd)
            * AstronomicalConstants.astronomicalUnitKilometres
        // Zoomed in, the renderer needs the *end* of the coming tick as well
        // as its start, so it can interpolate between snapshots instead of
        // extrapolating past one and stepping when the next arrives. That
        // doubles this pass, so it is asked for only at the fields of view
        // where the difference is worth a pixel — which are also the fields at
        // which almost nothing is on screen. See `SatelliteSubTick`.
        let subTick = SatelliteSubTick.isWorthComputing(
            fieldOfViewDegrees: camera.fieldOfViewDegrees
        ) ? SatelliteTracker.tickInterval : 0
        return (jd, location.currentLocation, sunEquatorial, sunDistance, subTick)
    }

    /// Publishes a finished snapshot. The visible-count reduction runs here
    /// because it is a scan of 16,000 samples and has no business on the
    /// render path.
    private func publish(snapshot: SatelliteSnapshot, visibleCount: Int) {
        satelliteSnapshot = snapshot
        visibleSatelliteCount = visibleCount
        if snapshot.propagationDuration > 0 {
            lastSatellitePropagationSeconds = snapshot.propagationDuration
        }
    }

    /// How many satellites are genuinely visible right now: sunlit and above
    /// the horizon. This is the count the satellite control shows, and it is
    /// also exactly the default render set's size, which is the point.
    private(set) var visibleSatelliteCount = 0

    // MARK: - Accuracy reporting

    /// Median element-set epoch of the loaded catalogue, as a Julian Day.
    ///
    /// The median rather than any single satellite's, because CelesTrak's
    /// element sets are generated at different times across a day or two and
    /// the question being answered — "is the displayed instant anywhere near
    /// the elements?" — is about the catalogue as a whole.
    private var medianElementEpochJulianDay: Double = 0

    /// True when the *time machine* has been scrubbed far enough from both real
    /// time and the element epochs that the satellite layer suppresses itself.
    ///
    /// This is the only case in which satellites are hidden. Aging elements at
    /// real time are drawn and labelled instead — see `satelliteStaleness`.
    var satellitesSuppressedBySimulatedTime: Bool {
        guard medianElementEpochJulianDay > 0, !satelliteDescriptors.isEmpty else { return false }
        return !SatelliteAccuracy.isDrawable(
            julianDay: time.julianDay,
            nowJulianDay: JulianDate.julianDay(from: Date()),
            epochJulianDay: medianElementEpochJulianDay
        )
    }

    /// Age in days of the catalogue's median element set at the displayed
    /// instant. The number the staleness wording is built from.
    var satelliteElementAgeDays: Double {
        guard medianElementEpochJulianDay > 0 else { return 0 }
        return time.julianDay - medianElementEpochJulianDay
    }

    /// How much the drawn satellite positions can be trusted right now.
    var satelliteStaleness: ElementSetStaleness {
        SatelliteAccuracy.staleness(ageDays: satelliteElementAgeDays)
    }

    /// The one honest sentence to put under the time bar about what on screen
    /// can still be trusted at the displayed instant. `nil` when everything is
    /// within its modelled range, which is the case at real time.
    ///
    /// Ordered by severity: satellites fail first and hardest, then the
    /// solar-system models at the edges of their window. Stars are never
    /// listed, because precession keeps them right across the whole range (only
    /// proper motion is missing, and that stays sub-pixel for centuries).
    var timeAccuracyCaveat: String? {
        var notes: [String] = []
        if satellitesEnabled && satellitesSuppressedBySimulatedTime {
            let days = Int(SatelliteAccuracy.maximumElementSetAgeDays)
            notes.append(
                "Satellites hidden: orbital element sets are only meaningful within about \(days) days of their epoch, so positions at this time would be meaningless rather than merely imprecise."
            )
        } else if satellitesEnabled, let caveat = satelliteStaleness.persistentCaveat {
            // `persistentCaveat`, not `caveat`: merely aging elements are
            // accurate enough that a permanent line here is noise. The exact
            // age stays available in the info panel on selection.
            notes.append("Satellite elements are \(satelliteElementAgeDays.formatted(.number.precision(.fractionLength(1)))) days old. \(caveat)")
        }
        let year = Calendar.current.component(.year, from: time.currentDate)
        if !EphemerisService.validYearRange.contains(year) {
            notes.append(
                "Outside \(EphemerisService.validYearRange.lowerBound)–\(EphemerisService.validYearRange.upperBound), planet positions are extrapolated beyond their fitted range."
            )
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    /// Lower-cased satellite names, parallel to `satelliteDescriptors`.
    private var satelliteSearchNames: [String] = []

    private func updateSatelliteDescriptors() async {
        satelliteDescriptors = await satelliteTracker.descriptors
        // Lower-cased once here rather than sixteen thousand times per
        // keystroke in `satelliteMatches`.
        satelliteSearchNames = satelliteDescriptors.map { $0.name.lowercased() }
        let epochs = satelliteDescriptors.map(\.epochJulianDay).sorted()
        medianElementEpochJulianDay = epochs.isEmpty ? 0 : epochs[epochs.count / 2]
    }

    /// Keeps trying to fetch fresh element sets for as long as the app runs.
    ///
    /// This used to be a single attempt per launch, and that is precisely why
    /// the app spent months on its bundled snapshot without anyone noticing:
    /// one source, one try, a silent failure, and no way back short of a
    /// relaunch. Now a failure schedules a retry (a minute, doubling to half an
    /// hour) so a transient outage heals inside the session, a success settles
    /// back to the polite one-a-day cadence, and the outcome is published for
    /// the satellite control to show.
    ///
    /// Detached, and never awaited by the propagation loop: a slow or hanging
    /// fetch must not delay a single satellite tick.
    private func startSatelliteRefreshLoop() {
        satelliteRefreshTask?.cancel()
        satelliteRefreshTask = Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // What is actually over the user's head right now, asked once
                // per refresh cycle rather than per tick, so the sweep can put
                // those objects first. A pass in progress is made current in
                // seconds instead of after the whole catalogue is walked.
                let priority = await self.satelliteTracker.aboveHorizonCatalogNumbers(
                    limit: SatelliteCatalogService.maximumTargetedRequests
                )
                let ageDays = await self.satelliteElementAgeDays
                let didRefresh = await SatelliteCatalogService.shared.refreshIfStale(
                    priorityCatalogNumbers: priority,
                    elementAgeDays: ageDays
                )
                if didRefresh {
                    await self.satelliteTracker.reload()
                    await self.updateSatelliteDescriptors()
                }
                await self.publishSatelliteRefreshStatus()
                let delay = await SatelliteCatalogService.shared.nextRefreshDelay()
                    ?? SatelliteCatalogService.minimumRefreshInterval
                // The floor is what stops a permanently-failing refresh turning
                // into a poll. It used to be 30 seconds, which — combined with
                // a freshness clock that never ticked (see
                // `SatelliteCatalogService.lastRefreshAge`) — is exactly what it
                // became. The backoff schedule already starts at a minute.
                try? await Task.sleep(
                    for: .seconds(max(delay, SatelliteCatalogService.initialRetryInterval))
                )
            }
        }
        startSatelliteWakeObservers()
    }

    /// Kicks the refresh loop when the machine comes back from sleep or the
    /// app returns to the foreground after a long idle.
    ///
    /// Without this, "refresh once a day" means "refresh once a day *while the
    /// app is awake*", and a laptop that is shut at midnight and opened at
    /// eight is a laptop whose satellite loop slept through its own schedule
    /// and then waited out the remainder of a timer that was measured against
    /// a clock that had stopped. Waking is precisely the moment the elements
    /// are most likely to be stale and the network most likely to be back.
    ///
    /// Both notifications are cheap and rare. Neither does any work itself: it
    /// cancels the sleeping task and restarts the loop, which re-evaluates the
    /// gates from scratch.
    private func startSatelliteWakeObservers() {
        guard satelliteWakeObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        satelliteWakeObservers.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.kickSatelliteRefresh() }
            }
        )
        satelliteWakeObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.kickSatelliteRefresh() }
            }
        )
    }

    private var satelliteWakeObservers: [NSObjectProtocol] = []
    private var lastSatelliteRefreshKick: Date?

    /// Restarts the refresh loop so its gates are re-evaluated immediately.
    ///
    /// Rate-limited to `wakeKickInterval`: `didBecomeActive` fires every time
    /// the user cmd-tabs back, and that must not become a way to hammer the
    /// sources. The one-day floor inside the service is the real guard; this
    /// is belt and braces so we do not even ask.
    private func kickSatelliteRefresh() {
        let now = Date()
        if let last = lastSatelliteRefreshKick,
           now.timeIntervalSince(last) < Self.wakeKickInterval { return }
        lastSatelliteRefreshKick = now
        startSatelliteRefreshLoop()
    }

    static let wakeKickInterval: TimeInterval = 5 * 60

    /// The last refresh attempt's outcome, mirrored onto the main actor so the
    /// satellite control can show it. Failure is no longer silent.
    private(set) var satelliteRefreshStatus = SatelliteCatalogService.RefreshStatus()

    private func publishSatelliteRefreshStatus() async {
        satelliteRefreshStatus = await SatelliteCatalogService.shared.refreshStatus
    }

    private func loadCatalog() async {
        do {
            // All of this runs on the CatalogService actor's executor, never
            // on the main actor: the 8.8 MB decode and the spatial-index build
            // happen while `isLoadingCatalog` is still true and the UI shows
            // its loading state. Only the assignments below touch @MainActor.
            async let indexResult = CatalogService.shared.loadStarIndex()
            async let searchIndexResult = CatalogService.shared.loadStarSearchIndex()
            async let linesResult = CatalogService.shared.loadConstellationLines()
            async let namesResult = CatalogService.shared.loadConstellations()
            async let deepSkyResult = CatalogService.shared.loadDeepSkyObjects()
            let (loadedIndex, loadedLines, loadedNames) = try await (indexResult, linesResult, namesResult)
            let loadedDeepSky = try await deepSkyResult
            let loadedStars = try await CatalogService.shared.loadStars()
            let loadedSearchIndex = try await searchIndexResult
            self.starIndex = loadedIndex
            self.starSearchIndex = loadedSearchIndex
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

    // MARK: - Object sky paths

    /// The span the user asked to see the selected object's track over, or nil
    /// when no path is showing.
    private(set) var pathRange: SkyPathRange?
    /// The computed track. Handed to the renderer in the frame snapshot.
    private(set) var skyPath: SkyPath?

    /// Identity of the track currently held, so `currentFrameData` can tell in
    /// a couple of string comparisons whether anything needs recomputing. The
    /// cost of *checking* is per frame; the cost of *building* is not.
    private var pathKey: String?
    private nonisolated(unsafe) var pathTask: Task<Void, Never>?

    /// Turns the path on for `range`, or off if that range is already showing.
    func togglePath(range: SkyPathRange) {
        if pathRange == range {
            pathRange = nil
            skyPath = nil
            pathKey = nil
        } else {
            pathRange = range
            pathKey = nil
            refreshSkyPathIfNeeded()
        }
    }

    /// How finely the path's anchor instant is quantised, per range, in days.
    ///
    /// This is what stops "recompute when the time range changes" from turning
    /// into "recompute every frame": a path anchored at *now* would otherwise
    /// have a different key every frame. A next-hour track is rebuilt at most
    /// once a minute (the far end moves by a quarter of a degree in that time);
    /// a whole-night track at most once an hour; a `tonight` track only when
    /// the night itself changes.
    private static func anchorQuantumDays(for range: SkyPathRange) -> Double {
        switch range {
        case .nextHour: return 1.0 / 1440.0
        case .next24Hours: return 1.0 / 24.0
        case .tonight: return 1.0
        case .custom: return .infinity
        }
    }

    private func pathIdentity(
        object: CelestialObject, range: SkyPathRange, julianDay: Double,
        location: GeographicLocation
    ) -> String {
        let quantum = Self.anchorQuantumDays(for: range)
        let anchor = quantum.isFinite ? (julianDay / quantum).rounded(.down) : 0
        return "\(object.id)|\(range)|\(anchor)|\(location.latitudeDegrees),\(location.longitudeDegrees)"
    }

    /// Rebuilds the track if — and only if — the selection, the range, the
    /// location or the quantised anchor instant has changed since the held one.
    private func refreshSkyPathIfNeeded() {
        guard let range = pathRange, let object = selectedObject else { return }
        let julianDay = time.julianDay
        let observer = location.currentLocation
        let key = pathIdentity(
            object: object, range: range, julianDay: julianDay, location: observer
        )
        guard key != pathKey else { return }
        pathKey = key

        if let details = object.satelliteDetails {
            buildSatellitePath(
                object: object, details: details, range: range,
                observer: observer, julianDay: julianDay
            )
            return
        }
        skyPath = Self.buildPath(
            object: object, range: range, observer: observer, julianDay: julianDay
        )
    }

    /// Everything that is not a satellite: the position is a closed-form
    /// function of time, so the whole track is a synchronous few hundred
    /// coordinate transforms.
    private static func buildPath(
        object: CelestialObject, range: SkyPathRange,
        observer: GeographicLocation, julianDay: Double
    ) -> SkyPath {
        switch object.kind {
        case .sun:
            return SkyPathBuilder.build(
                objectID: object.id, kind: .sun, range: range,
                equatorialAt: SunPosition.equatorialCoordinate(julianDay:),
                observer: observer, julianDay: julianDay
            )
        case .moon:
            return SkyPathBuilder.build(
                objectID: object.id, kind: .moon, range: range,
                equatorialAt: MoonPosition.equatorialCoordinate(julianDay:),
                observer: observer, julianDay: julianDay
            )
        case .planet, .dwarfPlanet:
            if let planet = Planet(rawValue: object.id) {
                return SkyPathBuilder.build(
                    objectID: object.id, kind: object.kind, range: range,
                    equatorialAt: {
                        PlanetPosition.equatorialCoordinate(planet: planet, julianDay: $0)
                    },
                    observer: observer, julianDay: julianDay
                )
            }
            fallthrough
        default:
            // Stars, deep-sky objects, constellations: fixed on the celestial
            // sphere, so the track is the diurnal arc. Precessed once to the
            // equinox of date, exactly as the renderer does.
            return SkyPathBuilder.build(
                objectID: object.id, kind: object.kind, range: range,
                fixedEquatorialOfDate: Precession.precess(
                    object.equatorial, julianDay: julianDay
                ),
                observer: observer, julianDay: julianDay
            )
        }
    }

    /// A satellite track. The sample times (and both accuracy gates) are
    /// resolved here; the propagation itself is one batched hop onto the
    /// tracker's actor, off the main thread.
    private func buildSatellitePath(
        object: CelestialObject, details: SatelliteDetails, range: SkyPathRange,
        observer: GeographicLocation, julianDay: Double
    ) {
        let epoch = satelliteDescriptors.indices.contains(details.descriptorIndex)
            ? satelliteDescriptors[details.descriptorIndex].epochJulianDay
            : julianDay
        let nowJulianDay = JulianDate.julianDay(from: Date())
        let (times, truncated) = SkyPathBuilder.satelliteSampleTimes(
            range: range, observer: observer, julianDay: julianDay,
            epochJulianDay: epoch, nowJulianDay: nowJulianDay
        )
        guard !times.isEmpty else {
            skyPath = SkyPathBuilder.satellitePath(
                objectID: object.id, range: range, times: [], horizontals: [],
                truncatedForAccuracy: true
            )
            return
        }
        pathTask?.cancel()
        let tracker = satelliteTracker
        let index = details.descriptorIndex
        pathTask = Task { [weak self] in
            let horizontals = await tracker.horizontalTrack(
                index: index, julianDays: times, observer: observer
            )
            guard !Task.isCancelled else { return }
            let path = SkyPathBuilder.satellitePath(
                objectID: object.id, range: range, times: times,
                horizontals: horizontals, truncatedForAccuracy: truncated
            )
            await MainActor.run {
                guard let self, self.selectedObject?.id == object.id else { return }
                self.skyPath = path
            }
        }
    }

    // MARK: - Tonight

    /// The dashboard's report, or nil while it is being computed.
    private(set) var tonightReport: TonightReport?
    private(set) var isComputingTonightReport = false
    var isTonightPanelPresented = false {
        didSet { if isTonightPanelPresented { refreshTonightReport() } }
    }
    private var tonightKey: String?
    private nonisolated(unsafe) var tonightTask: Task<Void, Never>?

    /// Recomputes the report when the night or the location changes.
    ///
    /// Keyed on the *night*, not the instant: scrubbing the time machine across
    /// one evening does not change what is worth looking at that evening, and
    /// rating nine hundred catalogue entries is not something to do per frame.
    func refreshTonightReport(force: Bool = false) {
        guard isTonightPanelPresented else { return }
        let observer = location.currentLocation
        let julianDay = time.julianDay
        let anchor = (julianDay - 0.5).rounded(.down)
        let key = "\(anchor)|\(observer.latitudeDegrees),\(observer.longitudeDegrees)"
        guard force || key != tonightKey else { return }
        tonightKey = key

        let catalogue = deepSkyObjects
        isComputingTonightReport = true
        tonightTask?.cancel()
        tonightTask = Task { [weak self] in
            let report = await Task.detached(priority: .userInitiated) {
                TonightPlanner.report(
                    observer: observer, julianDay: julianDay, deepSkyCatalogue: catalogue
                )
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.tonightReport = report
                self.isComputingTonightReport = false
            }
        }
    }

    // MARK: - Sky calendar

    /// Upcoming events, or empty while they are being computed.
    private(set) var calendarEvents: [AstronomicalEvent] = []
    private(set) var isComputingCalendar = false
    var isCalendarPresented = false {
        didSet { if isCalendarPresented { refreshCalendar() } }
    }
    private var calendarKey: String?
    private nonisolated(unsafe) var calendarTask: Task<Void, Never>?

    /// Rebuilds the calendar when the day or the location changes.
    ///
    /// Keyed on the day rather than the instant, for the same reason the
    /// Tonight report is keyed on the night: scrubbing the time machine across
    /// an afternoon does not change what is coming up, and solving a few
    /// hundred root finds is not per-frame work. The search itself runs on a
    /// detached task — it is several hundred thousand ephemeris evaluations,
    /// and none of them belong on the thread drawing the sky.
    func refreshCalendar(force: Bool = false) {
        guard isCalendarPresented else { return }
        let observer = location.currentLocation
        let julianDay = time.julianDay
        let key = "\(julianDay.rounded(.down))|\(observer.latitudeDegrees),\(observer.longitudeDegrees)"
        guard force || key != calendarKey else { return }
        calendarKey = key

        isComputingCalendar = true
        calendarTask?.cancel()
        calendarTask = Task { [weak self] in
            let events = await Task.detached(priority: .userInitiated) {
                EventCalendar.events(fromJulianDay: julianDay, observer: observer)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.calendarEvents = events
                self.isComputingCalendar = false
            }
        }
    }

    /// Opens a calendar event: moves the time machine to its instant and points
    /// the camera at whatever there is to look at.
    ///
    /// The order matters. The ephemeris is refreshed after the jump and before
    /// the camera is aimed, because "where is Jupiter" has a different answer at
    /// the new instant, and aiming first would fly the camera to where Jupiter
    /// was rather than where the event puts it.
    func open(event: AstronomicalEvent) {
        time.jump(to: event.date)
        refreshEphemeris()

        if let id = event.targetObjectID,
           let object = solarSystemObjects.first(where: { $0.id == id }) {
            flyToFocus(on: object)
            return
        }
        // A meteor radiant or the midpoint of a pairing: somewhere to look, but
        // nothing to select. The camera goes there; the selection is untouched.
        guard let equatorial = event.targetEquatorial else { return }
        let horizontal = CoordinateTransformService.horizontal(
            from: equatorial, observer: location.currentLocation, julianDay: event.julianDay
        )
        camera.flyTo(horizontal, fieldOfViewDegrees: min(camera.fieldOfViewDegrees, 60))
    }

    func currentFrameData() -> SkyFrameData {
        // Advance camera momentum/focus-flight in lockstep with the frame the
        // renderer is about to draw, so panning and flights stay smooth at
        // whatever refresh rate the display link is running.
        camera.tick()
        refreshSelectedSatellite()
        // A key comparison, not a rebuild: see `refreshSkyPathIfNeeded`.
        refreshSkyPathIfNeeded()
        refreshTonightReport()
        refreshCalendar()

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
        // Real time, as opposed to the possibly-scrubbed instant above. Only
        // the satellite gate uses it, to tell "aging elements, live sky" from
        // "the time machine is a month out". See `SatelliteAccuracy`.
        frame.nowJulianDay = JulianDate.julianDay(from: Date())
        frame.showAllSatellites = showAllSatellites
        // Sampled per frame so the transition is a continuous wash at whatever
        // rate the display runs at, rather than a step per SwiftUI update.
        frame.nightVisionStrength = nightVision.strength
        // Only ever the path of the object still selected — a stale track is
        // worse than none.
        frame.skyPath = skyPath?.objectID == selectedObject?.id ? skyPath : nil
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

    /// Result cap per category. Twenty is enough that a broad query still
    /// shows the interesting matches and few enough that no one category can
    /// crowd the others out of the list.
    private static let resultsPerCategory = 20

    func updateSearchResults() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        let lowered = query.lowercased()
        let condensedQuery = StarSearchIndex.normalize(query)

        // Ordered by how specific a hit in each category tends to be. A
        // solar-system body is the most likely thing meant by a bare name
        // ("Mars" is the planet, not a star), constellations and named stars
        // next, then the deep-sky and satellite catalogues, which are large
        // and full of near-miss substrings.
        var results: [CelestialObject] = solarSystemObjects.filter {
            $0.name.lowercased().contains(lowered)
        }

        results.append(contentsOf: constellationMatches(query: query))

        // Every star in the catalogue, by proper name, Bayer/Flamsteed, HR,
        // HD, HIP or Gliese designation. See `StarSearchIndex`.
        if let starSearchIndex {
            results.append(
                contentsOf: starSearchIndex
                    .matches(query: query, limit: Self.resultsPerCategory)
                    .map { $0.asCelestialObject }
            )
        }

        // Deep-sky objects match on either spelling: the common name
        // ("Andromeda Galaxy", "Pleiades") or the catalogue designation
        // ("M31", "NGC 7000"). Designations are compared with whitespace
        // removed so "NGC7000" and "NGC 7000" both hit.
        let deepSkyMatches = deepSkyObjects
            .filter { object in
                if let name = object.name?.lowercased(), name.contains(lowered) { return true }
                let designation = object.catalogName.lowercased()
                    .replacingOccurrences(of: " ", with: "")
                return designation.contains(condensedQuery)
                    || object.id.lowercased().contains(condensedQuery)
            }
            .sorted { $0.magnitude < $1.magnitude }
            .prefix(Self.resultsPerCategory)
            .map { $0.asCelestialObject }

        results.append(contentsOf: deepSkyMatches)
        results.append(contentsOf: satelliteMatches(lowered: lowered, query: query))
        searchResults = results
    }

    /// Constellations match on their name ("Orion", "Ursa Major") or on their
    /// three-letter IAU abbreviation ("Ori", "UMa") — the same abbreviation the
    /// HYG catalogue uses and the one that appears inside every Bayer
    /// designation, so it is a form users have already seen in this app. The
    /// matching and ranking live in `ConstellationDesignations`.
    ///
    /// Choosing one flies the camera to the constellation's centroid, which is
    /// the same approximate figure centre the name labels are placed at.
    private func constellationMatches(query: String) -> [CelestialObject] {
        ConstellationDesignations.rankedMatches(query: query, in: constellations)
            .prefix(Self.resultsPerCategory)
            .map { constellation in
                CelestialObject(
                    id: "constellation-\(constellation.name)",
                    name: constellation.name,
                    kind: .constellation,
                    equatorial: constellation.equatorial,
                    // A region of sky has no magnitude. Zero is a placeholder
                    // the info panel deliberately does not print.
                    magnitude: 0
                )
            }
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
            // Same accuracy gate the renderer applies: never offer a search
            // result the sky is refusing to draw, and never fly the camera to
            // a position the propagator cannot justify. See `SatelliteAccuracy`.
            guard SatelliteAccuracy.isReliable(
                julianDay: jd, epochJulianDay: sample.epochJulianDay
            ) else { continue }
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

    /// Where to point the camera for an object, in the same frame the renderer
    /// draws it in.
    ///
    /// Stars and deep-sky objects carry J2000 catalogue places and have to be
    /// precessed to the displayed epoch first — exactly as `SkyGeometryBuilder`
    /// does — or search would centre the camera a third of a degree off the
    /// star it just found, and further still under the time machine. Everything
    /// else (solar-system bodies, topocentric satellite places) is already
    /// of-date and must not be rotated again.
    private static func horizontalForCamera(
        object: CelestialObject, observer: GeographicLocation, julianDay: Double
    ) -> HorizontalCoordinate {
        // Constellation centroids are J2000 catalogue places like the star
        // and deep-sky ones, so they precess with them.
        let needsPrecession = object.kind == .star || object.kind == .deepSky
            || object.kind == .constellation
        let equatorial = needsPrecession
            ? Precession.precess(object.equatorial, julianDay: julianDay)
            : object.equatorial
        return CoordinateTransformService.horizontal(
            from: equatorial, observer: observer, julianDay: julianDay
        )
    }

    /// Recenters the camera on an object and selects it, instantly (used by
    /// search, where the object may currently be off-screen).
    func focus(on object: CelestialObject) {
        let horizontal = Self.horizontalForCamera(object: object, observer: location.currentLocation, julianDay: time.julianDay)
        camera.center(on: horizontal)
        selectedObject = object
        searchText = ""
        searchResults = []
    }

    /// Smoothly flies the camera to an object (double-click), zooming in a
    /// little if the current field of view is very wide.
    /// Selects and flies to a target the "Tonight" panel is offering.
    ///
    /// The panel deals in `TonightTarget`s, which carry only an id — deliberately,
    /// so the planner stays free of rendering types. Resolving that id back to a
    /// real object is this method's whole job.
    func selectAndFocus(targetID id: String) {
        if let object = solarSystemObjects.first(where: { $0.id == id }) {
            flyToFocus(on: object)
            return
        }
        if let deepSky = deepSkyObjects.first(where: { $0.id == id }) {
            flyToFocus(on: deepSky.asCelestialObject)
        }
    }

    func flyToFocus(on object: CelestialObject?) {
        guard let object else { return }
        let horizontal = Self.horizontalForCamera(object: object, observer: location.currentLocation, julianDay: time.julianDay)
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
