//
//  RenderPerformanceTests.swift
//  AstronomyTests
//
//  Measures the per-frame CPU pipeline against the *real* bundled catalogues,
//  stage by stage, at several fields of view.
//
//  This is a measurement harness, not a pass/fail gate on wall-clock time:
//  the assertions are deliberately loose (they only catch a pipeline that has
//  become catastrophically slow, or one that silently stopped producing
//  geometry). CI machines and Debug builds are far too variable for a tight
//  budget assertion to mean anything. The numbers printed by
//  `RenderProfiler.formattedReport()` are the actual product.
//
//  Everything here is synchronous on purpose: an `async` XCTest crashes this
//  test host, so the catalogues are decoded directly from `Bundle.main`
//  rather than through `CatalogService`.
//

import XCTest
@testable import Astronomy

/// Deliberately *not* `@MainActor`. A main-actor-isolated class released
/// inside a `@MainActor` XCTestCase takes the isolated-deinit path and aborts
/// the test host in libmalloc — which is the real shape of this project's
/// "tests crash the host" folklore. Everything measured here is nonisolated,
/// so the plain default is also the correct one.
final class RenderPerformanceTests: XCTestCase {

    private func probe(_ m: String) { fputs("PROBE " + m + "\n", stderr); fflush(stderr) }

    // MARK: - Fixtures (decoded once for the whole class)

    private static func decode<T: Decodable>(_ name: String) -> T? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static let stars: [Star] = decode("stars") ?? []
    private static let starIndex: StarIndex? = stars.isEmpty ? nil : StarIndex(stars: stars)
    private static let deepSky: [DeepSkyObject] =
        (decode("deepsky") as [DeepSkyObject]?)?.filter { $0.type.isRenderable } ?? []
    private static let lines: [ConstellationLineSegment] = decode("constellations") ?? []
    private static let constellations: [Constellation] = decode("constellation_names") ?? []
    private static let starsByID: [Int: Star] =
        Dictionary(stars.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    /// A synthetic 16,000-satellite snapshot with the same shape as a real
    /// propagation tick: index-ordered samples plus the altitude ordering the
    /// geometry builder binary-searches. Positions are spread over a LEO shell
    /// so the altitude distribution — which is what drives the per-frame cost —
    /// is realistic. Using SGP4 for real here would measure the propagator,
    /// which does not run on the frame thread.
    private static let satelliteSnapshot: SatelliteSnapshot = {
        var samples: [SatelliteSample] = []
        samples.reserveCapacity(16_000)
        var seed: UInt64 = 0x5DEECE66D
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        for i in 0..<16_000 {
            let radius = 6_878.0 + next() * 800.0
            let u = next() * 2 - 1
            let phi = next() * 2 * Double.pi
            let s = (1 - u * u).squareRoot()
            let position = SIMD3(radius * s * cos(phi), radius * s * sin(phi), radius * u)
            let velocity = SIMD3(next() - 0.5, next() - 0.5, next() - 0.5) * 15.0
            samples.append(
                SatelliteSample(
                    index: i,
                    catalogNumber: 25_000 + i,
                    regime: .lowEarth,
                    isNotable: i % 500 == 0,
                    epochJulianDay: RenderPerformanceTests.julianDay,
                    position: position,
                    velocity: velocity,
                    illumination: i % 3 == 0 ? .sunlit : .umbra,
                    altitudeDegreesAtSnapshot: next() * 180.0 - 90.0
                )
            )
        }
        let order = samples.indices
            .sorted { samples[$0].altitudeDegreesAtSnapshot < samples[$1].altitudeDegreesAtSnapshot }
            .map { Int32($0) }
        return SatelliteSnapshot(
            julianDay: RenderPerformanceTests.julianDay, samples: samples,
            propagationDuration: 0, altitudeOrder: order
        )
    }()

    private static let satelliteDescriptors: [SatelliteDescriptor] = (0..<16_000).map { i in
        SatelliteDescriptor(
            catalogNumber: 25_000 + i,
            name: "SAT \(i)",
            regime: .lowEarth,
            internationalDesignator: "20-\(i)A",
            epochJulianDay: RenderPerformanceTests.julianDay,
            isNotable: i % 500 == 0
        )
    }

    /// 2026-01-15 05:00 UTC — a dark, deep sky over the Bay Area, which is the
    /// expensive case: the limiting magnitude is at its deepest, so the star
    /// cull keeps the most candidates it ever will.
    private static let julianDay: Double = 2_461_055.708333
    private static let observer = GeographicLocation(
        latitudeDegrees: 37.77, longitudeDegrees: -122.42
    )
    private static let viewport = CGSize(width: 1512, height: 900)

    private static func frameData(fieldOfViewDegrees: Double) -> SkyFrameData {
        var frame = SkyFrameData(
            stars: stars,
            solarSystemObjects: EphemerisService.solarSystemObjects(julianDay: julianDay),
            constellationLines: lines,
            constellations: constellations,
            deepSkyObjects: deepSky,
            starsByID: starsByID,
            starIndex: starIndex,
            observerLocation: observer,
            julianDay: julianDay,
            cameraCenter: HorizontalCoordinate(altitudeDegrees: 45, azimuthDegrees: 180),
            cameraFieldOfViewDegrees: fieldOfViewDegrees,
            viewportSize: viewport
        )
        frame.sunHorizontal = HorizontalCoordinate(altitudeDegrees: -40, azimuthDegrees: 0)
        frame.satelliteSnapshot = satelliteSnapshot
        frame.satelliteDescriptors = satelliteDescriptors
        frame.satellitesEnabled = true
        return frame
    }

    /// Fields of view spanning the whole zoom range the app allows.
    private static let fieldsOfView: [Double] = [120, 90, 45, 15, 3]

    // MARK: - Measurement

    func testPerFrameGeometryCostAcrossFieldsOfView() throws {
        probe("enter test")
        try XCTSkipIf(Self.stars.isEmpty, "star catalogue unavailable in this bundle")

        let iterations = 30
        var summary: [String] = ["", "=== per-frame CPU pipeline (real catalogues) ==="]
        summary.append("catalogue: \(Self.stars.count) stars, \(Self.deepSky.count) deep-sky, "
                       + "\(Self.satelliteSnapshot.samples.count) satellites")
        #if DEBUG
        summary.append("build configuration: DEBUG (unoptimized — expect several times Release)")
        #else
        summary.append("build configuration: RELEASE")
        #endif

        probe("stars=\(Self.stars.count) dso=\(Self.deepSky.count) lines=\(Self.lines.count) sats=\(Self.satelliteSnapshot.samples.count)")
        let engine = LabelLayoutEngine()

        for fov in Self.fieldsOfView {
            probe("fov \(fov) start")
            let frame = Self.frameData(fieldOfViewDegrees: fov)
            let profiler = RenderProfiler()

            // One untimed pass so first-touch page faults and any lazy
            // initialisation don't land in the sample window.
            var warm = SkyGeometryBuilder(frameData: frame)
            warm.run()
            probe("fov \(fov) warm ok \(warm.pointVertices.count)")

            var lastVertexCount = 0
            var lastLabelCount = 0
            for _ in 0..<iterations {
                var builder = SkyGeometryBuilder(frameData: frame)
                builder.profiler = profiler
                builder.run()
                lastVertexCount = builder.pointVertices.count

                let candidates = builder.labelCandidates
                let labels = profiler.measure(.labelLayout) {
                    engine.layout(candidates: candidates, viewportSize: Self.viewport)
                }
                lastLabelCount = labels.count
            }

            probe("fov \(fov) loop ok")
            summary.append("")
            summary.append(
                profiler.formattedReport(
                    title: String(
                        format: "FOV %.0f deg — %d point vertices, %d labels",
                        fov, lastVertexCount, lastLabelCount
                    )
                )
            )

            XCTAssertGreaterThan(lastVertexCount, 0, "no geometry produced at FOV \(fov)")
            // Sanity ceiling only: one second per frame is not a budget, it is
            // a tripwire for a pipeline that has regressed by orders of
            // magnitude.
            XCTAssertLessThan(
                profiler.statistics(for: .geometryTotal).meanMilliseconds, 1000.0,
                "geometry build has regressed catastrophically at FOV \(fov)"
            )
        }

        let text = summary.joined(separator: "\n")
        print(text)
        // stdout from the test host is not forwarded to `xcodebuild`'s log, so
        // the numbers are attached to the result bundle as well. Retrieve with
        //   xcrun xcresulttool export attachments --path <bundle> --output-path <dir>
        let attachment = XCTAttachment(string: text)
        attachment.name = "frame-stage-timings"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The other half of the per-second CPU bill: the 2.5 Hz SGP4 pass.
    ///
    /// It runs on a background actor and is spread across cores, so it never
    /// appears in a frame's own stage timings — but it is the largest single
    /// block of arithmetic the app performs, it happens two and a half times a
    /// second, and if it saturates the machine the main thread feels it. This
    /// measures one full single-threaded pass over the real bundled catalogue,
    /// which is the number the tracker's parallelism has to divide down.
    func testSGP4PropagationThroughputOverTheRealCatalogue() throws {
        guard let url = Bundle.main.url(forResource: "satellites", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("satellite catalogue unavailable in this bundle")
        }
        let elements = TwoLineElement.parseCatalog(text)
        let satellites = elements.compactMap(Satellite.init(tle:))
        try XCTSkipIf(satellites.isEmpty, "no satellites parsed")

        // Warm: first call per satellite does the deep initialisation.
        for satellite in satellites { _ = satellite.propagate(julianDay: Self.julianDay) }

        var passes: [Double] = []
        for pass in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            var kept = 0
            for satellite in satellites {
                if satellite.propagate(julianDay: Self.julianDay + Double(pass) * 1e-4) != nil {
                    kept += 1
                }
            }
            passes.append(Double(DispatchTime.now().uptimeNanoseconds - start) * 1e-6)
            XCTAssertGreaterThan(kept, 0)
        }

        var text2 = ["", "=== SGP4 single-threaded pass over \(satellites.count) satellites ==="]
        #if DEBUG
        text2.append("build configuration: DEBUG")
        #else
        text2.append("build configuration: RELEASE")
        #endif
        for (i, ms) in passes.enumerated() {
            text2.append(String(format: "  pass %d: %8.2f ms  (%.2f us/satellite)",
                                i, ms, ms * 1000 / Double(satellites.count)))
        }
        text2.append(String(
            format: "  tracker runs this every %.2f s, spread over %d cores",
            SatelliteTracker.tickInterval, ProcessInfo.processInfo.activeProcessorCount
        ))
        let joined = text2.joined(separator: "\n")
        print(joined)
        let attachment = XCTAttachment(string: joined)
        attachment.name = "sgp4-throughput"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// The fused projector must be the *same* transform as the chain it replaced,
/// not a faster approximation of it. This checks it against the original
/// composition — precess, equatorial->horizontal, stereographic project —
/// over a grid covering the whole sky, both poles, the RA seam, and a range of
/// observer latitudes, camera orientations and fields of view.
final class SkyProjectorEquivalenceTests: XCTestCase {

    private func frame(
        latitude: Double, longitude: Double, julianDay: Double,
        center: HorizontalCoordinate, fov: Double, viewport: CGSize
    ) -> SkyFrameData {
        var f = SkyFrameData.empty
        f.observerLocation = GeographicLocation(latitudeDegrees: latitude, longitudeDegrees: longitude)
        f.julianDay = julianDay
        f.cameraCenter = center
        f.cameraFieldOfViewDegrees = fov
        f.viewportSize = viewport
        return f
    }

    func testHorizontalDirectionMatchesTheOriginalChain() throws {
        let cases: [(Double, Double, Double)] = [
            (37.77, -122.42, 2_461_055.7),
            (-33.87, 151.21, 2_460_000.123),
            (89.9, 0.0, 2_451_545.0),
            (-89.9, 179.9, 2_470_000.5),
            (0.0, 0.0, 2_455_000.25),
        ]
        var checked = 0
        for (lat, lon, jd) in cases {
            let f = frame(
                latitude: lat, longitude: lon, julianDay: jd,
                center: HorizontalCoordinate(altitudeDegrees: 30, azimuthDegrees: 100),
                fov: 90, viewport: CGSize(width: 1000, height: 700)
            )
            let matrix = Precession.rotationMatrix(julianDay: jd)
            let projector = SkyProjector(frameData: f, precessionMatrix: matrix)

            for raStep in 0..<24 {
                for decStep in 0...18 {
                    let equatorial = EquatorialCoordinate(
                        rightAscensionDegrees: Double(raStep) * 15.0 + 0.37,
                        declinationDegrees: -90.0 + Double(decStep) * 10.0
                    )
                    // Original chain.
                    let ofDate = Precession.precess(equatorial, matrix: matrix)
                    let expected = CoordinateTransformService.horizontal(
                        from: ofDate, observer: f.observerLocation, julianDay: jd
                    )
                    let actual = projector.horizontal(
                        direction: projector.direction(j2000: equatorial)
                    )
                    XCTAssertEqual(
                        actual.altitudeDegrees, expected.altitudeDegrees, accuracy: 1e-9,
                        "altitude at ra \(equatorial.rightAscensionDegrees) dec \(equatorial.declinationDegrees) lat \(lat)"
                    )
                    // Azimuth is meaningless at the zenith and wraps at 360.
                    if abs(expected.altitudeDegrees) < 89.99 {
                        var delta = actual.azimuthDegrees - expected.azimuthDegrees
                        if delta > 180 { delta -= 360 }
                        if delta < -180 { delta += 360 }
                        XCTAssertEqual(delta, 0, accuracy: 1e-8, "azimuth at dec \(equatorial.declinationDegrees)")
                    }
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 2000)
    }

    func testProjectedNDCMatchesTheOriginalChain() throws {
        let centers = [
            HorizontalCoordinate(altitudeDegrees: 0, azimuthDegrees: 0),
            HorizontalCoordinate(altitudeDegrees: 45, azimuthDegrees: 180),
            HorizontalCoordinate(altitudeDegrees: 89.5, azimuthDegrees: 270),
            HorizontalCoordinate(altitudeDegrees: -60, azimuthDegrees: 33),
        ]
        let viewports = [CGSize(width: 1512, height: 900), CGSize(width: 800, height: 800)]
        var agreed = 0
        var projected = 0

        for center in centers {
            for fov in [150.0, 90.0, 30.0, 3.0] {
                for viewport in viewports {
                    let jd = 2_461_055.7
                    let f = frame(
                        latitude: 37.77, longitude: -122.42, julianDay: jd,
                        center: center, fov: fov, viewport: viewport
                    )
                    let matrix = Precession.rotationMatrix(julianDay: jd)
                    let projector = SkyProjector(frameData: f, precessionMatrix: matrix)

                    for raStep in 0..<36 {
                        for decStep in 0...18 {
                            let equatorial = EquatorialCoordinate(
                                rightAscensionDegrees: Double(raStep) * 10.0,
                                declinationDegrees: -90.0 + Double(decStep) * 10.0
                            )
                            let ofDate = Precession.precess(equatorial, matrix: matrix)
                            let horizontal = CoordinateTransformService.horizontal(
                                from: ofDate, observer: f.observerLocation, julianDay: jd
                            )
                            let expected = CoordinateTransformService.stereographicProject(
                                horizontal: horizontal, center: center, fieldOfViewDegrees: fov
                            ).map { CoordinateTransformService.aspectCorrected($0, viewportSize: viewport) }

                            let actual = projector.project(
                                direction: projector.direction(j2000: equatorial)
                            )

                            switch (expected, actual) {
                            case (nil, nil):
                                agreed += 1
                            case let (e?, a?):
                                XCTAssertEqual(a.x, e.x, accuracy: 1e-7)
                                XCTAssertEqual(a.y, e.y, accuracy: 1e-7)
                                agreed += 1
                                projected += 1
                            default:
                                XCTFail("disagreed on whether the point projects at all: "
                                        + "ra \(equatorial.rightAscensionDegrees) "
                                        + "dec \(equatorial.declinationDegrees) fov \(fov)")
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(agreed, 10_000)
        XCTAssertGreaterThan(projected, 1_000)
    }
}

