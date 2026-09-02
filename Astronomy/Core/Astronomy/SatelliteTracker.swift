//
//  SatelliteTracker.swift
//  Astronomy
//
//  Keeps ~16,000 satellites moving in real time without spending the frame
//  budget on it.
//
//  The naive shape of this feature — propagate every satellite every frame —
//  does not fit. SGP4 costs on the order of a microsecond per satellite per
//  call, so 16,000 of them is ~16 ms of pure arithmetic. At 120 Hz the whole
//  frame is 8 ms. It would not be close.
//
//  What actually works is to separate the two rates:
//
//   * **Propagation** runs here, on this actor, off the main thread and
//     parallelised across cores with a `TaskGroup`, at a modest 2.5 Hz. That
//     is the expensive, accurate step.
//   * **Extrapolation** runs on the render thread, every frame, and is a
//     single fused multiply-add: `r + v * dt`. SGP4 hands back velocity as
//     well as position, so this costs nothing.
//
//  Measured over the standard verification set (see
//  `testLinearExtrapolationOverOneTickStaysBelowAPixel`), the extrapolation
//  error over one 0.4-second tick is under a metre for ordinary low orbits and
//  a hundred metres or so for the awkward eccentric cases: partly the neglected
//  quadratic term, partly the fact that SGP4's reported velocity is an
//  osculating two-body velocity rather than the exact derivative of its own
//  position function. At a 90-degree field that is a hundredth of a pixel, and
//  the straight line is the whole answer.
//
//  **It stops being the whole answer when the camera is zoomed in.** The zoom
//  limit is now 0.15 degrees rather than 3, so the same error is worth up to
//  about a pixel (measured over the bundled catalogue: median 0.2, worst 1.3),
//  and it is applied as a *step* every time a snapshot lands. So at narrow
//  fields the caller asks for `subTickIntervalSeconds` as well, this pass
//  propagates the end of the tick too, and the renderer interpolates between
//  the two instead of extrapolating past one — see `SatelliteSubTick`. That
//  doubles this pass, which is why it is asked for only where it shows.
//
//  The result is motion that is both correct and smooth at every zoom: the sky
//  updates at the display's full rate, and nothing visibly steps.
//

import Foundation
import os
import simd

actor SatelliteTracker {

    /// Propagation ticks per second. Fast enough that the linear extrapolation
    /// between ticks stays far below a pixel, slow enough that the whole pass
    /// costs a small fraction of one core. Going much slower would start to let
    /// the neglected quadratic term show on fast LEO passes.
    static let tickRateHertz: Double = 2.5
    static var tickInterval: TimeInterval { 1.0 / tickRateHertz }

    /// Number of satellites one `TaskGroup` child handles. Large enough that
    /// task overhead is negligible, small enough that the work spreads evenly
    /// over the cores.
    private static let chunkSize = 512

    private static let logger = Logger(subsystem: "Astronomy", category: "satellites")

    private var satellites: [Satellite] = []
    private(set) var descriptors: [SatelliteDescriptor] = []
    private(set) var isLoaded = false

    /// The most recent propagation, kept so the refresh scheduler can ask what
    /// is actually overhead without propagating anything itself.
    ///
    /// Storing it costs one reference assignment per tick on an array the
    /// tracker has just built and is about to hand out anyway — no copy, no
    /// scan, and nothing at all on the frame path. The alternative (deriving
    /// the list every tick, 2.5 times a second, for a consumer that reads it
    /// once a day) would be exactly the kind of per-frame CPU work this
    /// renderer has spent a lot of effort not doing.
    private var lastSnapshot: SatelliteSnapshot?

    /// Catalogue numbers of the objects that were sunlit and above the horizon
    /// at the last tick, brightest prospects first — highest in the sky first,
    /// which is the best proxy this app has for "most likely to be looked at".
    ///
    /// Used to decide which element sets a refresh should fetch *first*, so a
    /// pass that is happening now is current within seconds rather than after
    /// the whole catalogue has been walked.
    func aboveHorizonCatalogNumbers(limit: Int) -> [Int] {
        guard let snapshot = lastSnapshot, limit > 0 else { return [] }
        // `altitudeOrder` is ascending, so the end of it is the top of the sky.
        var out: [Int] = []
        out.reserveCapacity(limit)
        for orderIndex in snapshot.altitudeOrder.reversed() {
            let sample = snapshot.samples[Int(orderIndex)]
            guard sample.altitudeDegreesAtSnapshot > 0 else { break }
            guard sample.illumination.isSunlit else { continue }
            out.append(sample.catalogNumber)
            if out.count == limit { break }
        }
        return out
    }

    // MARK: - Tracks

    /// Look angles for one satellite at each of `julianDays`, for the "Show
    /// Path" feature.
    ///
    /// This lives on the actor for the same reason `propagate` does: the
    /// propagator carries integration state and is only ever touched by one
    /// task at a time. It is deliberately a *batch* call — one actor hop for a
    /// whole track rather than one per sample — and it is called when the
    /// selection or the range changes, never per frame.
    ///
    /// A `nil` entry means the propagator refused that instant (a decayed
    /// object, or elements the model rejects); the caller stops the track
    /// there rather than drawing through the gap.
    func horizontalTrack(
        index: Int, julianDays: [Double], observer: GeographicLocation
    ) -> [HorizontalCoordinate?] {
        guard index >= 0, index < satellites.count else { return [] }
        let satellite = satellites[index]
        return julianDays.map { jd in
            guard let state = satellite.propagate(julianDay: jd) else { return nil }
            return TopocentricTransform.lookAngles(
                satellitePositionTEME: state.position,
                observer: observer,
                julianDay: jd
            ).horizontal
        }
    }

    // MARK: - Loading

    /// Loads the catalogue and initialises every propagator. Safe to call more
    /// than once; subsequent calls are no-ops.
    func load() async {
        guard !isLoaded else { return }
        do {
            let loaded = try await SatelliteCatalogService.shared.loadSatellites()
            satellites = loaded
            descriptors = loaded.map(SatelliteDescriptor.init)
            isLoaded = true
        } catch {
            Self.logger.error("Satellite catalogue failed to load: \(error.localizedDescription)")
            isLoaded = true // Don't retry in a loop; the sky renders without satellites.
        }
    }

    /// Replaces the catalogue after a successful refresh.
    func reload() async {
        isLoaded = false
        satellites = []
        descriptors = []
        await SatelliteCatalogService.shared.invalidate()
        await load()
    }

    // MARK: - Propagation

    /// Propagates every satellite to `julianDay` and returns the snapshot.
    ///
    /// The observer position and Sun direction are passed in rather than
    /// recomputed per satellite: both are constants across the whole pass, and
    /// hoisting them out removes 16,000 redundant sidereal-time evaluations.
    ///
    /// When `subTickIntervalSeconds` is non-zero each satellite is propagated
    /// *twice*: once to `julianDay` and once to the end of the tick. That
    /// second state is what lets the renderer interpolate between snapshots
    /// instead of extrapolating past one, which is the difference between a
    /// satellite that steps at every tick boundary and one that does not — see
    /// `SatelliteSubTick`. It doubles this pass, so the caller only asks for it
    /// when the camera is zoomed in far enough for the difference to be worth a
    /// pixel; at a wide field this parameter is zero and nothing changes.
    func propagate(
        julianDay: Double,
        observer: GeographicLocation,
        sunEquatorial: EquatorialCoordinate,
        sunDistanceKilometres: Double,
        subTickIntervalSeconds: Double = 0
    ) async -> SatelliteSnapshot {
        guard !satellites.isEmpty else { return .empty }

        let start = ContinuousClock.now
        let sunDirection = TopocentricTransform.sunDirection(equatorial: sunEquatorial)
        let observerPosition = TopocentricTransform.observerPositionTEME(
            observer: observer, julianDay: julianDay
        )
        let latitude = Angle.degreesToRadians(observer.latitudeDegrees)
        let lst = Angle.degreesToRadians(
            CoordinateTransformService.localSiderealTimeDegrees(
                julianDay: julianDay, longitudeDegrees: observer.longitudeDegrees
            )
        )
        let basis = ObserverBasis(latitude: latitude, localSiderealTime: lst)

        let satellites = self.satellites
        let chunkSize = Self.chunkSize
        let chunkCount = (satellites.count + chunkSize - 1) / chunkSize

        // Each child owns a disjoint index range, so the propagators it mutates
        // are touched by exactly one task. That disjointness is the whole
        // justification for `Satellite` being `@unchecked Sendable`.
        // The end of the tick, for the interpolation. Expressed in days once,
        // outside the loop, because it is the same offset for every satellite.
        let subTickDays = subTickIntervalSeconds / 86_400.0
        let wantsSubTick = subTickIntervalSeconds > 0

        var chunks = [[SatelliteSample]](repeating: [], count: chunkCount)
        var subTickChunks = [[SatelliteSubTickState]](repeating: [], count: chunkCount)
        await withTaskGroup(of: (Int, [SatelliteSample], [SatelliteSubTickState]).self) { group in
            for chunk in 0..<chunkCount {
                let lower = chunk * chunkSize
                let upper = min(lower + chunkSize, satellites.count)
                group.addTask {
                    var samples: [SatelliteSample] = []
                    samples.reserveCapacity(upper - lower)
                    var subTicks: [SatelliteSubTickState] = []
                    if wantsSubTick { subTicks.reserveCapacity(upper - lower) }
                    for index in lower..<upper {
                        let satellite = satellites[index]
                        guard let state = satellite.propagate(julianDay: julianDay) else {
                            // Decayed objects and elements the model rejects are
                            // simply absent from the snapshot. Drawing a
                            // position the propagator itself refused to produce
                            // would be worse than drawing nothing.
                            continue
                        }
                        if wantsSubTick {
                            // If the model refuses the *end* of the tick but
                            // accepted the start, fall back to the straight
                            // line for this one object: it then behaves exactly
                            // as it did before, rather than vanishing.
                            let end = satellite.propagate(julianDay: julianDay + subTickDays)
                            subTicks.append(
                                SatelliteSubTickState(
                                    position: end?.position
                                        ?? (state.position + state.velocity * subTickIntervalSeconds),
                                    velocity: end?.velocity ?? state.velocity
                                )
                            )
                        }
                        let shadow = TopocentricTransform.shadowState(
                            satellitePositionTEME: state.position,
                            sunDirection: sunDirection,
                            sunDistanceKm: sunDistanceKilometres
                        )
                        samples.append(
                            SatelliteSample(
                                index: index,
                                catalogNumber: satellite.catalogNumber,
                                regime: satellite.regime,
                                isNotable: satellite.isNotable,
                                epochJulianDay: satellite.epochJulianDay,
                                position: state.position,
                                velocity: state.velocity,
                                illumination: shadow.illumination,
                                altitudeDegreesAtSnapshot: basis.altitudeDegrees(
                                    satellitePosition: state.position,
                                    observerPosition: observerPosition
                                ),
                                sunlitFraction: Float(shadow.sunlitFraction)
                            )
                        )
                    }
                    return (chunk, samples, subTicks)
                }
            }
            for await (chunk, samples, subTicks) in group {
                chunks[chunk] = samples
                subTickChunks[chunk] = subTicks
            }
        }

        var samples: [SatelliteSample] = []
        samples.reserveCapacity(satellites.count)
        for chunk in chunks { samples.append(contentsOf: chunk) }

        var subTickStates: [SatelliteSubTickState] = []
        if wantsSubTick {
            subTickStates.reserveCapacity(samples.count)
            for chunk in subTickChunks { subTickStates.append(contentsOf: chunk) }
        }

        // Altitude ordering for the renderer's band search. Built here, on this
        // actor, so the main thread never pays for it.
        var altitudeOrder = [Int32](0..<Int32(samples.count))
        altitudeOrder.sort {
            samples[Int($0)].altitudeDegreesAtSnapshot
                < samples[Int($1)].altitudeDegreesAtSnapshot
        }

        let duration = start.duration(to: .now)
        let snapshot = SatelliteSnapshot(
            julianDay: julianDay,
            samples: samples,
            propagationDuration: TimeInterval(duration.components.seconds)
                + Double(duration.components.attoseconds) * 1e-18,
            altitudeOrder: altitudeOrder,
            subTickStates: subTickStates,
            subTickIntervalSeconds: wantsSubTick ? subTickIntervalSeconds : 0
        )
        lastSnapshot = snapshot
        return snapshot
    }

    /// The observer's rotation into the topocentric frame, precomputed once per
    /// pass. `TopocentricTransform.lookAngles` recomputes the sidereal time
    /// itself, which is right for a one-off call and wasteful 16,000 times over.
    struct ObserverBasis: Sendable {
        let sinLat: Double, cosLat: Double, sinLST: Double, cosLST: Double

        init(latitude: Double, localSiderealTime: Double) {
            sinLat = sin(latitude); cosLat = cos(latitude)
            sinLST = sin(localSiderealTime); cosLST = cos(localSiderealTime)
        }

        /// Altitude above the horizon in degrees, without the azimuth (which
        /// the coarse pre-filter does not need).
        func altitudeDegrees(
            satellitePosition: SIMD3<Double>, observerPosition: SIMD3<Double>
        ) -> Double {
            let range = satellitePosition - observerPosition
            let zenith = cosLat * cosLST * range.x + cosLat * sinLST * range.y + sinLat * range.z
            let magnitude = simd_length(range)
            guard magnitude > 0 else { return 0 }
            return Angle.radiansToDegrees(asin(max(-1.0, min(1.0, zenith / magnitude))))
        }
    }
}
