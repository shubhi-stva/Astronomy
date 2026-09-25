//
//  VSOP87.swift
//  Astronomy
//
//  Heliocentric positions of the eight major planets from the VSOP87 planetary
//  theory (Bretagnon & Francou, Astronomy & Astrophysics 202, 309 (1988)),
//  variant **D**: spherical coordinates — longitude L, latitude B, radius R —
//  referred to the mean dynamical ecliptic and equinox **of the date**.
//
//  This replaced the two-body Keplerian element fit that the app started with.
//  The Keplerian table has no planetary perturbations at all, and the mutual
//  pull of Jupiter and Saturn alone moves each of them by tens of arcminutes
//  over a synodic cycle — a whole Moon diameter at the narrow fields this app
//  reaches. VSOP87 carries those perturbations as trigonometric series in the
//  planets' mean longitudes, and is the theory Meeus's "Astronomical
//  Algorithms" (Chapters 32-33) and most planetarium software are built on.
//
//  Each coordinate is
//
//      X = Σ_n  T^n · Σ_k A_k cos(B_k + C_k T)          T in Julian millennia (TT) from J2000.0
//
//  Data. `vsop87d.json` is a truncation of the original series files
//  (VSOP87D.mer … VSOP87D.nep from the IMCCE, ftp.imcce.fr/pub/ephem/planets/
//  vsop87). A term is kept when its contribution A·|T|^n over 1800-2050
//  (|T| ≤ 0.2) is at least 3×10⁻⁸ — about 0.006 arcseconds, or 4.5 km in R.
//  That leaves 6,771 of 31,577 terms and bounds the worst-case (all dropped
//  terms in phase) truncation error at 1.6" in heliocentric longitude for
//  Saturn, the largest, and under 0.7" for the Earth. The generating script is
//  kept out of the repo; see DATA_SOURCES.md for the exact rule so it can be
//  reproduced.
//
//  Cost. Evaluating a planet is a few hundred to fifteen hundred cosines —
//  under 20 µs — and the Earth about 300. The tables are decoded once, lazily,
//  and shared.
//

import Foundation
import simd

enum VSOP87 {

    enum Body: String, CaseIterable, Sendable {
        case mercury, venus, earth, mars, jupiter, saturn, uranus, neptune
    }

    /// One heliocentric spherical position: ecliptic longitude and latitude in
    /// radians, distance in AU, all of date.
    struct Spherical: Equatable, Sendable {
        let longitude: Double
        let latitude: Double
        let radius: Double

        /// Rectangular ecliptic-of-date coordinates, AU.
        var rectangular: SIMD3<Double> {
            let cb = cos(latitude)
            return SIMD3(radius * cb * cos(longitude), radius * cb * sin(longitude), radius * sin(latitude))
        }
    }

    /// The series for one coordinate: one flat `[A, B, C, A, B, C, …]` array
    /// per power of T.
    struct Series: Sendable {
        let powers: [[Double]]

        @inline(__always)
        func evaluate(t: Double) -> Double {
            var total = 0.0
            var tPower = 1.0
            for terms in powers {
                var sum = 0.0
                var i = 0
                let count = terms.count
                while i + 2 < count {
                    sum += terms[i] * cos(terms[i + 1] + terms[i + 2] * t)
                    i += 3
                }
                total += sum * tPower
                tPower *= t
            }
            return total
        }
    }

    struct BodySeries: Sendable {
        let longitude: Series
        let latitude: Series
        let radius: Series
    }

    /// The decoded tables. Loaded on first use from the bundled JSON, which is
    /// the one place in `Core/` that touches the bundle — kept behind this
    /// accessor so the ephemeris functions stay pure functions of time.
    nonisolated(unsafe) private static let tables: [Body: BodySeries] = loadTables()

    private static func loadTables() -> [Body: BodySeries] {
        let candidates = [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks
        guard let url = candidates.lazy.compactMap({ $0.url(forResource: "vsop87d", withExtension: "json") }).first,
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: [String: [[Double]]]].self, from: data)
        else {
            assertionFailure("vsop87d.json is missing from the bundle")
            return [:]
        }
        var result: [Body: BodySeries] = [:]
        for body in Body.allCases {
            guard let entry = raw[body.rawValue],
                  let l = entry["L"], let b = entry["B"], let r = entry["R"] else { continue }
            result[body] = BodySeries(
                longitude: Series(powers: l), latitude: Series(powers: b), radius: Series(powers: r)
            )
        }
        return result
    }

    /// True once the bundled tables decoded; false means every position from
    /// this file is zero, which the tests check for and the app never sees.
    static var isAvailable: Bool { !tables.isEmpty }

    /// Heliocentric ecliptic-of-date position for a **TT** Julian Day.
    static func heliocentric(_ body: Body, julianDayTT jd: Double) -> Spherical {
        guard let series = tables[body] else {
            return Spherical(longitude: 0, latitude: 0, radius: 0)
        }
        let t = (jd - JulianDate.j2000) / 365_250.0
        var longitude = series.longitude.evaluate(t: t).truncatingRemainder(dividingBy: 2 * .pi)
        if longitude < 0 { longitude += 2 * .pi }
        return Spherical(
            longitude: longitude,
            latitude: series.latitude.evaluate(t: t),
            radius: series.radius.evaluate(t: t)
        )
    }

    /// Heliocentric rectangular ecliptic-of-date position, AU, for a TT
    /// Julian Day.
    @inline(__always)
    static func heliocentricRectangular(_ body: Body, julianDayTT jd: Double) -> SIMD3<Double> {
        heliocentric(body, julianDayTT: jd).rectangular
    }
}
