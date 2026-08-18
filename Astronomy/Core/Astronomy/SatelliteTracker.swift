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
//     well as position, so this costs nothing and is accurate to metres over
//     the 0.4 s between ticks (a LEO satellite's acceleration is ~8.7 m/s^2,
//     so the neglected quadratic term is 0.5 * 8.7 * 0.4^2 ~ 0.7 m at 400 km
//     range: about 0.0001 degrees, four orders of magnitude below a pixel).
//
//  The result is motion that is both correct and perfectly smooth: the sky
//  updates at the display's full rate, and nothing ever visibly steps.
//

import Foundation
import os
import simd

actor SatelliteTracker {

    /// Propagation ticks per second. Chosen as the slowest rate at which the
    /// linear extrapolation between ticks stays sub-metre; going slower would
    /// save little (the pass is already a small fraction of a core) and would
    /// start to let the quadratic term show.
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
    func propagate(
        julianDay: Double,
        observer: GeographicLocation,
        sunEquatorial: EquatorialCoordinate,
        sunDistanceKilometres: Double
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
        var chunks = [[SatelliteSample]](repeating: [], count: chunkCount)
        await withTaskGroup(of: (Int, [SatelliteSample]).self) { group in
            for chunk in 0..<chunkCount {
                let lower = chunk * chunkSize
                let upper = min(lower + chunkSize, satellites.count)
                group.addTask {
                    var samples: [SatelliteSample] = []
                    samples.reserveCapacity(upper - lower)
                    for index in lower..<upper {
                        let satellite = satellites[index]
                        guard let state = satellite.propagate(julianDay: julianDay) else {
                            // Decayed objects and elements the model rejects are
                            // simply absent from the snapshot. Drawing a
                            // position the propagator itself refused to produce
                            // would be worse than drawing nothing.
                            continue
                        }
                        let illumination = TopocentricTransform.illumination(
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
                                position: state.position,
                                velocity: state.velocity,
                                illumination: illumination,
                                altitudeDegreesAtSnapshot: basis.altitudeDegrees(
                                    satellitePosition: state.position,
                                    observerPosition: observerPosition
                                )
                            )
                        )
                    }
                    return (chunk, samples)
                }
            }
            for await (chunk, samples) in group {
                chunks[chunk] = samples
            }
        }

        var samples: [SatelliteSample] = []
        samples.reserveCapacity(satellites.count)
        for chunk in chunks { samples.append(contentsOf: chunk) }

        let duration = start.duration(to: .now)
        return SatelliteSnapshot(
            julianDay: julianDay,
            samples: samples,
            propagationDuration: TimeInterval(duration.components.seconds)
                + Double(duration.components.attoseconds) * 1e-18
        )
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
