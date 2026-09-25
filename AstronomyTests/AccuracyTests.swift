//
//  AccuracyTests.swift
//  AstronomyTests
//
//  The ephemeris against JPL Horizons.
//
//  Every row below is a Horizons ephemeris line (EPHEM_TYPE=OBSERVER,
//  QUANTITIES=2,4,9,20,23,24, ANG_FORMAT=DEG, EXTRA_PREC=YES, APPARENT=AIRLESS)
//  fetched 2026-09-15: apparent RA/Dec referred to the true equator and
//  equinox of date, apparent azimuth/elevation (airless, topocentric — only for
//  the rows with a site), apparent magnitude, observer distance, and phase
//  angle. Geocentric rows use CENTER=500@399; the topocentric rows use a
//  geodetic site at 122.42 W, 37.77 N, 0 m (San Francisco).
//
//  Tolerances are stated per body from what the models claim, with some
//  headroom, and the residuals are printed so a regression shows up as a
//  number, not just a failure.
//

import XCTest
import simd
@testable import Astronomy

final class HorizonsAccuracyTests: XCTestCase {

    struct Row {
        let body: String
        let year: Int, month: Int, day: Int, hour: Int, minute: Int
        let topocentric: Bool
        let ra: Double, dec: Double
        let azimuth: Double?, altitude: Double?
        let magnitude: Double
        let deltaAU: Double
        let phaseAngle: Double

        var julianDay: Double {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let date = calendar.date(from: DateComponents(
                year: year, month: month, day: day, hour: hour, minute: minute
            ))!
            return JulianDate.julianDay(from: date)
        }
    }

    static let sanFrancisco = GeographicLocation(latitudeDegrees: 37.77, longitudeDegrees: -122.42)

    static let rows: [Row] = [
        Row(body: "sun", year: 1850, month: 6, day: 15, hour: 0, minute: 0, topocentric: false, ra: 82.899599903, dec: 23.29607919, azimuth: nil, altitude: nil, magnitude: -26.708, deltaAU: 1.01603359938321, phaseAngle: 0.0),
        Row(body: "sun", year: 1950, month: 1, day: 1, hour: 0, minute: 0, topocentric: false, ra: 280.884733739, dec: -23.070740433, azimuth: nil, altitude: nil, magnitude: -26.779, deltaAU: 0.98324362521005, phaseAngle: 0.0),
        Row(body: "sun", year: 2000, month: 1, day: 1, hour: 12, minute: 0, topocentric: false, ra: 281.278375239, dec: -23.03243013, azimuth: nil, altitude: nil, magnitude: -26.779, deltaAU: 0.98332762652701, phaseAngle: 0.0),
        Row(body: "sun", year: 2026, month: 1, day: 1, hour: 0, minute: 0, topocentric: false, ra: 281.494699195, dec: -23.017248343, azimuth: nil, altitude: nil, magnitude: -26.779, deltaAU: 0.98332666254872, phaseAngle: 0.0),
        Row(body: "sun", year: 2026, month: 9, day: 15, hour: 6, minute: 0, topocentric: false, ra: 173.047783979, dec: 3.003705303, azimuth: nil, altitude: nil, magnitude: -26.73, deltaAU: 1.00574026601128, phaseAngle: 0.0),
        Row(body: "sun", year: 2045, month: 7, day: 4, hour: 18, minute: 0, topocentric: false, ra: 104.304621446, dec: 22.784042127, azimuth: nil, altitude: nil, magnitude: -26.706, deltaAU: 1.01668186139325, phaseAngle: 0.0),
        Row(body: "moon", year: 1850, month: 6, day: 15, hour: 0, minute: 0, topocentric: false, ra: 150.897532291, dec: 13.091235605, azimuth: nil, altitude: nil, magnitude: -9.094, deltaAU: 0.00245924241929, phaseAngle: 115.0081),
        Row(body: "moon", year: 1950, month: 1, day: 1, hour: 0, minute: 0, topocentric: false, ra: 58.451755325, dec: 24.152480764, azimuth: nil, altitude: nil, magnitude: -11.655, deltaAU: 0.0026713350217, phaseAngle: 38.6481),
        Row(body: "moon", year: 2000, month: 1, day: 1, hour: 12, minute: 0, topocentric: false, ra: 222.452200851, dec: -10.90065378, azimuth: nil, altitude: nil, magnitude: -8.566, deltaAU: 0.00268998925442, phaseAngle: 122.6718),
        Row(body: "moon", year: 2026, month: 1, day: 1, hour: 0, minute: 0, topocentric: false, ra: 63.920306258, dec: 26.403701421, azimuth: nil, altitude: nil, magnitude: -11.997, deltaAU: 0.00241343753005, phaseAngle: 34.104),
        Row(body: "moon", year: 2026, month: 9, day: 15, hour: 6, minute: 0, topocentric: false, ra: 218.164424693, dec: -20.25655052, azimuth: nil, altitude: nil, magnitude: -8.135, deltaAU: 0.00264223783978, phaseAngle: 129.8983),
        Row(body: "moon", year: 2045, month: 7, day: 4, hour: 18, minute: 0, topocentric: false, ra: 343.387408991, dec: -5.196342976, azimuth: nil, altitude: nil, magnitude: -10.981, deltaAU: 0.00269797210476, phaseAngle: 59.416),
        Row(body: "mercury", year: 1850, month: 6, day: 15, hour: 0, minute: 0, topocentric: false, ra: 75.759249295, dec: 18.717695607, azimuth: nil, altitude: nil, magnitude: 4.546, deltaAU: 0.56727052313927, phaseAngle: 161.9606),
        Row(body: "mercury", year: 1950, month: 1, day: 1, hour: 0, minute: 0, topocentric: false, ra: 301.88147065, dec: -21.471268343, azimuth: nil, altitude: nil, magnitude: -0.531, deltaAU: 1.00298279472208, phaseAngle: 76.942),
        Row(body: "mercury", year: 2000, month: 1, day: 1, hour: 12, minute: 0, topocentric: false, ra: 272.074637466, dec: -24.418901716, azimuth: nil, altitude: nil, magnitude: -0.734, deltaAU: 1.41546946904999, phaseAngle: 18.2386),
        Row(body: "mercury", year: 2026, month: 1, day: 1, hour: 0, minute: 0, topocentric: false, ra: 268.524035973, dec: -24.001291126, azimuth: nil, altitude: nil, magnitude: -0.595, deltaAU: 1.37755900276913, phaseAngle: 26.0729),
        Row(body: "mercury", year: 2026, month: 9, day: 15, hour: 6, minute: 0, topocentric: false, ra: 187.003646423, dec: -2.795128714, azimuth: nil, altitude: nil, magnitude: -0.492, deltaAU: 1.3323998302249, phaseAngle: 35.9493),
        Row(body: "mercury", year: 2045, month: 7, day: 4, hour: 18, minute: 0, topocentric: false, ra: 130.035200839, dec: 17.429797457, azimuth: nil, altitude: nil, magnitude: 0.836, deltaAU: 0.74430290272501, phaseAngle: 112.8669),
        Row(body: "venus", year: 1850, month: 6, day: 15, hour: 0, minute: 0, topocentric: false, ra: 111.9468005, dec: 23.541392413, azimuth: nil, altitude: nil, magnitude: -3.894, deltaAU: 1.46462371086111, phaseAngle: 39.2879),
        Row(body: "venus", year: 1950, month: 1, day: 1, hour: 0, minute: 0, topocentric: false, ra: 319.234862202, dec: -15.151215943, azimuth: nil, altitude: nil, magnitude: -4.919, deltaAU: 0.37468337166614, phaseAngle: 124.781),
        Row(body: "venus", year: 2000, month: 1, day: 1, hour: 12, minute: 0, topocentric: false, ra: 239.892759465, dec: -18.448919196, azimuth: nil, altitude: nil, magnitude: -4.066, deltaAU: 1.13757924245212, phaseAngle: 58.9239),
        Row(body: "venus", year: 2026, month: 1, day: 1, hour: 0, minute: 0, topocentric: false, ra: 280.056455581, dec: -23.622404581, azimuth: nil, altitude: nil, magnitude: -3.911, deltaAU: 1.70995207339244, phaseAngle: 1.9648),
        Row(body: "venus", year: 2026, month: 9, day: 15, hour: 6, minute: 0, topocentric: false, ra: 208.900937624, dec: -17.427737439, azimuth: nil, altitude: nil, magnitude: -4.764, deltaAU: 0.44868957367299, phaseAngle: 115.3938),
        Row(body: "venus", year: 2045, month: 7, day: 4, hour: 18, minute: 0, topocentric: false, ra: 134.005081338, dec: 19.076585553, azimuth: nil, altitude: nil, magnitude: -3.895, deltaAU: 1.43749024804377, phaseAngle: 41.4513),
        Row(body: "mars", year: 1850, month: 6, day: 15, hour: 0, minute: 0, topocentric: false, ra: 140.347284785, dec: 16.864764836, azimuth: nil, altitude: nil, magnitude: 1.61, deltaAU: 2.0403052317977, phaseAngle: 29.6653),
        Row(body: "mars", year: 1950, month: 1, day: 1, hour: 0, minute: 0, topocentric: false, ra: 183.027933187, dec: 1.425600572, azimuth: nil, altitude: nil, magnitude: 0.549, deltaAU: 1.21551730045793, phaseAngle: 35.8428),
        Row(body: "mars", year: 2000, month: 1, day: 1, hour: 12, minute: 0, topocentric: false, ra: 330.516799463, dec: -13.182481236, azimuth: nil, altitude: nil, magnitude: 1.086, deltaAU: 1.84968786270204, phaseAngle: 31.4632),
        Row(body: "mars", year: 2026, month: 1, day: 1, hour: 0, minute: 0, topocentric: false, ra: 283.879610807, dec: -23.720007274, azimuth: nil, altitude: nil, magnitude: 1.072, deltaAU: 2.41069876736921, phaseAngle: 1.583),
        Row(body: "mars", year: 2026, month: 9, day: 15, hour: 6, minute: 0, topocentric: false, ra: 114.192929513, dec: 22.341475466, azimuth: nil, altitude: nil, magnitude: 1.212, deltaAU: 1.76758681574913, phaseAngle: 34.5482),
        Row(body: "mars", year: 2045, month: 7, day: 4, hour: 18, minute: 0, topocentric: false, ra: 87.00282459, dec: 23.923352867, azimuth: nil, altitude: nil, magnitude: 1.514, deltaAU: 2.48733835995121, phaseAngle: 10.4625),
        Row(body: "jupiter", year: 1850, month: 6, day: 15, hour: 0, minute: 0, topocentric: false, ra: 166.640545083, dec: 7.096036175, azimuth: nil, altitude: nil, magnitude: -1.949, deltaAU: 5.49952790434932, phaseAngle: 10.6376),
        Row(body: "jupiter", year: 1950, month: 1, day: 1, hour: 0, minute: 0, topocentric: false, ra: 309.048450528, dec: -19.21910621, azimuth: nil, altitude: nil, magnitude: -1.987, deltaAU: 5.93536699854896, phaseAngle: 4.9634),
        Row(body: "jupiter", year: 2000, month: 1, day: 1, hour: 12, minute: 0, topocentric: false, ra: 23.867836618, dec: 8.594261973, azimuth: nil, altitude: nil, magnitude: -2.521, deltaAU: 4.62117524331177, phaseAngle: 11.0305),
        Row(body: "jupiter", year: 2026, month: 1, day: 1, hour: 0, minute: 0, topocentric: false, ra: 113.124332352, dec: 21.979135798, azimuth: nil, altitude: nil, magnitude: -2.67, deltaAU: 4.24266571436379, phaseAngle: 2.0305),
        Row(body: "jupiter", year: 2026, month: 9, day: 15, hour: 6, minute: 0, topocentric: false, ra: 139.242943245, dec: 16.389316279, azimuth: nil, altitude: nil, magnitude: -1.829, deltaAU: 6.08453010651398, phaseAngle: 6.3721),
        Row(body: "jupiter", year: 2045, month: 7, day: 4, hour: 18, minute: 0, topocentric: false, ra: 344.108011862, dec: -8.017225995, azimuth: nil, altitude: nil, magnitude: -2.607, deltaAU: 4.41946475498293, phaseAngle: 10.0191),
        Row(body: "saturn", year: 1850, month: 6, day: 15, hour: 0, minute: 0, topocentric: false, ra: 18.472051716, dec: 5.274393684, azimuth: nil, altitude: nil, magnitude: 0.706, deltaAU: 9.7868814334994, phaseAngle: 5.6001),
        Row(body: "saturn", year: 1950, month: 1, day: 1, hour: 0, minute: 0, topocentric: false, ra: 171.083465972, dec: 6.027991724, azimuth: nil, altitude: nil, magnitude: 0.771, deltaAU: 8.96248840413593, phaseAngle: 5.6525),
        Row(body: "saturn", year: 2000, month: 1, day: 1, hour: 12, minute: 0, topocentric: false, ra: 38.765386155, dec: 12.614763512, azimuth: nil, altitude: nil, magnitude: 0.104, deltaAU: 8.65279676096631, phaseAngle: 5.3163),
        Row(body: "saturn", year: 2026, month: 1, day: 1, hour: 0, minute: 0, topocentric: false, ra: 357.380959207, dec: -3.596394732, azimuth: nil, altitude: nil, magnitude: 1.007, deltaAU: 9.71523207732461, phaseAngle: 5.7424),
        Row(body: "saturn", year: 2026, month: 9, day: 15, hour: 6, minute: 0, topocentric: false, ra: 12.792182814, dec: 2.564242129, azimuth: nil, altitude: nil, magnitude: 0.414, deltaAU: 8.49082089186147, phaseAngle: 2.1451),
        Row(body: "saturn", year: 2045, month: 7, day: 4, hour: 18, minute: 0, topocentric: false, ra: 244.552160292, dec: -19.450345613, azimuth: nil, altitude: nil, magnitude: 0.205, deltaAU: 9.17498543240261, phaseAngle: 3.5111),
        Row(body: "uranus", year: 1850, month: 6, day: 15, hour: 0, minute: 0, topocentric: false, ra: 27.406566822, dec: 10.71416059, azimuth: nil, altitude: nil, magnitude: 5.901, deltaAU: 20.4604913108516, phaseAngle: 2.3737),
        Row(body: "uranus", year: 1950, month: 1, day: 1, hour: 0, minute: 0, topocentric: false, ra: 92.929757008, dec: 23.689733365, azimuth: nil, altitude: nil, magnitude: 5.489, deltaAU: 17.9698607764709, phaseAngle: 0.3728),
        Row(body: "uranus", year: 2000, month: 1, day: 1, hour: 12, minute: 0, topocentric: false, ra: 317.474810891, dec: -17.020330403, azimuth: nil, altitude: nil, magnitude: 5.942, deltaAU: 20.7271711300464, phaseAngle: 1.6031),
        Row(body: "uranus", year: 2026, month: 1, day: 1, hour: 0, minute: 0, topocentric: false, ra: 55.737099009, dec: 19.509648526, azimuth: nil, altitude: nil, magnitude: 5.646, deltaAU: 18.7552916988723, phaseAngle: 1.9526),
        Row(body: "uranus", year: 2026, month: 9, day: 15, hour: 6, minute: 0, topocentric: false, ra: 63.813932808, dec: 21.101401307, azimuth: nil, altitude: nil, magnitude: 5.68, deltaAU: 19.1304502900322, phaseAngle: 2.842),
        Row(body: "uranus", year: 2045, month: 7, day: 4, hour: 18, minute: 0, topocentric: false, ra: 147.091264197, dec: 14.003149207, azimuth: nil, altitude: nil, magnitude: 5.595, deltaAU: 19.1036464360166, phaseAngle: 2.1018),
        Row(body: "neptune", year: 1850, month: 6, day: 15, hour: 0, minute: 0, topocentric: false, ra: 339.049103809, dec: -9.641298999, azimuth: nil, altitude: nil, magnitude: 7.855, deltaAU: 29.6680353227553, phaseAngle: 1.8658),
        Row(body: "neptune", year: 1950, month: 1, day: 1, hour: 0, minute: 0, topocentric: false, ra: 196.527070851, dec: -5.311858477, azimuth: nil, altitude: nil, magnitude: 7.932, deltaAU: 30.4037113779932, phaseAngle: 1.8453),
        Row(body: "neptune", year: 2000, month: 1, day: 1, hour: 12, minute: 0, topocentric: false, ra: 305.432832031, dec: -19.213240976, azimuth: nil, altitude: nil, magnitude: 7.853, deltaAU: 31.024498221734, phaseAngle: 0.7299),
        Row(body: "neptune", year: 2026, month: 1, day: 1, hour: 0, minute: 0, topocentric: false, ra: 0.077610938, dec: -1.418611036, azimuth: nil, altitude: nil, magnitude: 7.767, deltaAU: 30.0579192796247, phaseAngle: 1.8506),
        Row(body: "neptune", year: 2026, month: 9, day: 15, hour: 6, minute: 0, topocentric: false, ra: 3.588087429, dec: 0.00945594, azimuth: nil, altitude: nil, magnitude: 7.681, deltaAU: 28.8903836615154, phaseAngle: 0.3728),
        Row(body: "neptune", year: 2045, month: 7, day: 4, hour: 18, minute: 0, topocentric: false, ra: 44.592142917, dec: 15.119952828, azimuth: nil, altitude: nil, magnitude: 7.783, deltaAU: 30.3578649196746, phaseAngle: 1.6303),
        Row(body: "pluto", year: 1850, month: 6, day: 15, hour: 0, minute: 0, topocentric: false, ra: 33.281393331, dec: -4.339104485, azimuth: nil, altitude: nil, magnitude: 15.952, deltaAU: 49.3913290643643, phaseAngle: 0.9828),
        Row(body: "pluto", year: 1950, month: 1, day: 1, hour: 0, minute: 0, topocentric: false, ra: 142.965653539, dec: 23.293300452, azimuth: nil, altitude: nil, magnitude: 14.595, deltaAU: 35.5511031235687, phaseAngle: 0.9715),
        Row(body: "pluto", year: 2000, month: 1, day: 1, hour: 12, minute: 0, topocentric: false, ra: 251.41916987, dec: -11.394274163, azimuth: nil, altitude: nil, magnitude: 13.902, deltaAU: 31.0643527312227, phaseAngle: 0.9488),
        Row(body: "pluto", year: 2026, month: 1, day: 1, hour: 0, minute: 0, topocentric: false, ra: 305.936045877, dec: -23.219923591, azimuth: nil, altitude: nil, magnitude: 14.572, deltaAU: 36.3280661073045, phaseAngle: 0.6118),
        Row(body: "pluto", year: 2026, month: 9, day: 15, hour: 6, minute: 0, topocentric: false, ra: 306.670142066, dec: -23.60015718, azimuth: nil, altitude: nil, magnitude: 14.524, deltaAU: 34.9350789648525, phaseAngle: 1.2226),
        Row(body: "pluto", year: 2045, month: 7, day: 4, hour: 18, minute: 0, topocentric: false, ra: 340.342536977, dec: -21.044188213, azimuth: nil, altitude: nil, magnitude: 15.073, deltaAU: 39.7334023987121, phaseAngle: 1.1365),
        Row(body: "moon", year: 2026, month: 1, day: 1, hour: 4, minute: 0, topocentric: true, ra: 67.095927977, dec: 26.594323907, azimuth: 106.429655575, altitude: 63.413959452, magnitude: -12.104, deltaAU: 0.00237376112412, phaseAngle: 31.4298),
        Row(body: "moon", year: 2026, month: 9, day: 15, hour: 6, minute: 0, topocentric: true, ra: 217.408829285, dec: -20.720672566, azimuth: 261.382945292, altitude: -23.607834802, magnitude: -8.093, deltaAU: 0.00265898286978, phaseAngle: 130.3693),
        Row(body: "moon", year: 2026, month: 3, day: 20, hour: 3, minute: 0, topocentric: true, ra: 10.471587923, dec: 7.479981442, azimuth: 275.788849303, altitude: 4.750440365, magnitude: -5.405, deltaAU: 0.00246886403117, phaseAngle: 166.6441),
        Row(body: "mars", year: 2026, month: 1, day: 1, hour: 4, minute: 0, topocentric: true, ra: 284.017747255, dec: -23.709251874, azimuth: 264.093021158, altitude: -33.034357428, magnitude: 1.132, deltaAU: 2.41059070759512, phaseAngle: 1.5574),
        Row(body: "mars", year: 2026, month: 9, day: 15, hour: 6, minute: 0, topocentric: true, ra: 114.19341002, dec: 22.340316078, azimuth: 28.107791100, altitude: -24.524769642, magnitude: 1.212, deltaAU: 1.76760460147678, phaseAngle: 34.5488),
        Row(body: "mars", year: 2026, month: 3, day: 20, hour: 3, minute: 0, topocentric: true, ra: 345.494586042, dec: -7.364629321, azimuth: 279.641425588, altitude: -24.000406410, magnitude: 1.162, deltaAU: 2.3132882374042, phaseAngle: 11.2777),
        Row(body: "venus", year: 2026, month: 1, day: 1, hour: 4, minute: 0, topocentric: true, ra: 280.284124853, dec: -23.614487693, azimuth: 266.309638657, altitude: -35.926778314, magnitude: -3.911, deltaAU: 1.71002254048717, phaseAngle: 1.916),
        Row(body: "venus", year: 2026, month: 9, day: 15, hour: 6, minute: 0, topocentric: true, ra: 208.896748334, dec: -17.43041886, azimuth: 269.390101604, altitude: -28.488875437, magnitude: -4.764, deltaAU: 0.4487098820022, phaseAngle: 115.3961),
        Row(body: "venus", year: 2026, month: 3, day: 20, hour: 3, minute: 0, topocentric: true, ra: 15.988886074, dec: 5.848957215, azimuth: 271.133723421, altitude: 8.111478988, magnitude: -3.899, deltaAU: 1.60831194387644, phaseAngle: 24.4351),
        Row(body: "sun", year: 2026, month: 1, day: 1, hour: 4, minute: 0, topocentric: true, ra: 281.676657604, dec: -23.004752058, azimuth: 266.148886870, altitude: -34.516098854, magnitude: -26.779, deltaAU: 0.98334787113626, phaseAngle: 0.0),
        Row(body: "sun", year: 2026, month: 9, day: 15, hour: 6, minute: 0, topocentric: true, ra: 173.046725071, dec: 3.002143659, azimuth: 317.451087768, altitude: -40.001687464, magnitude: -26.73, deltaAU: 1.00576771492354, phaseAngle: 0.0),
        Row(body: "sun", year: 2026, month: 3, day: 20, hour: 3, minute: 0, topocentric: true, ra: 359.550873639, dec: -0.195281309, azimuth: 276.443646816, altitude: -8.556797311, magnitude: -26.751, deltaAU: 0.99578833943115, phaseAngle: 0.0),
    ]

    static func separationArcseconds(_ a: EquatorialCoordinate, ra: Double, dec: Double) -> Double {
        let v1 = Precession.unitVector(a)
        let v2 = Precession.unitVector(EquatorialCoordinate(rightAscensionDegrees: ra, declinationDegrees: dec))
        let cross = simd_length(simd_cross(v1, v2))
        let dot = simd_dot(v1, v2)
        return atan2(cross, dot) * 206_264.806
    }

    /// Arcsecond tolerance per body: the theory's own claim plus headroom.
    static func toleranceArcseconds(body: String) -> Double {
        switch body {
        // Measured worst residuals over the six epochs: Sun 0.35", planets
        // 0.5" (Uranus 1.1", Neptune 2.0"), Moon 3.8", Pluto 39".
        case "moon": return 8         // Meeus Ch. 47 full series: ~10" claimed
        case "pluto": return 60       // Keplerian two-body fit
        case "sun": return 1
        case "neptune", "uranus": return 3
        default: return 1.5           // VSOP87D truncated at 3e-8, nutation to 0.5"
        }
    }

    func testGeocentricApparentPlacesMatchHorizons() {
        var worst: [String: Double] = [:]
        for row in Self.rows where !row.topocentric {
            let objects = EphemerisService.solarSystemObjects(julianDay: row.julianDay)
            guard let object = objects.first(where: { $0.id == row.body }) else {
                XCTFail("no \(row.body)"); continue
            }
            let residual = Self.separationArcseconds(object.equatorial, ra: row.ra, dec: row.dec)
            worst[row.body] = max(worst[row.body] ?? 0, residual)
            XCTAssertLessThan(
                residual, Self.toleranceArcseconds(body: row.body),
                "\(row.body) \(row.year)-\(row.month)-\(row.day): \(residual)\" from Horizons"
            )
            // Distance, to a part in ten thousand (light-time corrected).
            let deltaKm = row.deltaAU * AstronomicalConstants.astronomicalUnitKilometres
            XCTAssertEqual(
                object.distanceKilometres! / deltaKm, 1.0, accuracy: ["pluto": 5e-4, "moon": 2e-4][row.body] ?? 2e-5,
                "\(row.body) \(row.year): distance"
            )
        }
        for (body, residual) in worst.sorted(by: { $0.key < $1.key }) {
            print("Horizons residual \(body): worst \(String(format: "%.2f", residual))\"")
        }
    }

    func testMagnitudesMatchHorizons() {
        for row in Self.rows where !row.topocentric {
            let objects = EphemerisService.solarSystemObjects(julianDay: row.julianDay)
            guard let object = objects.first(where: { $0.id == row.body }) else { continue }
            // Horizons's Moon and Saturn models differ slightly from the ones
            // used here; a quarter of a magnitude is invisible in a sprite.
            let tolerance = ["moon": 0.35, "saturn": 0.3, "pluto": 0.4][row.body] ?? 0.15
            XCTAssertEqual(
                object.magnitude, row.magnitude, accuracy: tolerance,
                "\(row.body) \(row.year)-\(row.month): magnitude \(object.magnitude) vs \(row.magnitude)"
            )
            if row.body != "sun", row.body != "moon" {
                XCTAssertEqual(
                    object.phaseAngleDegrees ?? -1, row.phaseAngle, accuracy: 0.05,
                    "\(row.body) \(row.year): phase angle"
                )
            }
        }
    }

    /// Topocentric places and look angles from San Francisco: this is the whole
    /// chain the renderer uses — parallax, apparent sidereal time, the
    /// horizontal transform — short of refraction (Horizons AIRLESS).
    func testTopocentricPlacesAndLookAnglesMatchHorizons() {
        for row in Self.rows where row.topocentric {
            let objects = EphemerisService.solarSystemObjects(
                julianDay: row.julianDay, observer: Self.sanFrancisco
            )
            guard let object = objects.first(where: { $0.id == row.body }) else {
                XCTFail("no \(row.body)"); continue
            }
            let residual = Self.separationArcseconds(object.equatorial, ra: row.ra, dec: row.dec)
            XCTAssertLessThan(
                residual, Self.toleranceArcseconds(body: row.body),
                "\(row.body) topocentric \(row.month)/\(row.day): \(residual)\""
            )

            let horizontal = CoordinateTransformService.horizontal(
                from: object.equatorial, observer: Self.sanFrancisco, julianDay: row.julianDay
            )
            let altitudeError = abs(horizontal.altitudeDegrees - row.altitude!) * 3600
            var azimuthDelta = horizontal.azimuthDegrees - row.azimuth!
            if azimuthDelta > 180 { azimuthDelta -= 360 }
            if azimuthDelta < -180 { azimuthDelta += 360 }
            let azimuthError = abs(azimuthDelta) * 3600 * cos(Angle.degreesToRadians(row.altitude!))
            XCTAssertLessThan(altitudeError, Self.toleranceArcseconds(body: row.body) + 2,
                              "\(row.body) altitude off by \(altitudeError)\"")
            XCTAssertLessThan(azimuthError, Self.toleranceArcseconds(body: row.body) + 2,
                              "\(row.body) azimuth off by \(azimuthError)\"")
            print("look angles \(row.body) \(row.month)/\(row.day): alt \(String(format: "%.1f", altitudeError))\" az \(String(format: "%.1f", azimuthError))\"")
        }
    }

    /// The projector must land a solar-system body at the same screen point
    /// as the direct transform does (they share the frame), and a J2000 star
    /// reduced through the projector must agree with `ApparentFrame`.
    func testProjectorAgreesWithTheDirectTransform() {
        let row = Self.rows.first { $0.topocentric && $0.body == "moon" }!
        var frame = SkyFrameData.empty
        frame.observerLocation = Self.sanFrancisco
        frame.julianDay = row.julianDay
        frame.cameraCenter = HorizontalCoordinate(altitudeDegrees: row.altitude!, azimuthDegrees: row.azimuth!)
        frame.cameraFieldOfViewDegrees = 10
        frame.viewportSize = CGSize(width: 1000, height: 1000)
        frame.refractionEnabled = false
        let apparent = ApparentFrame(julianDayUT: row.julianDay)
        let projector = SkyProjector(frameData: frame, apparentFrame: apparent)

        let moon = EphemerisService.solarSystemObjects(julianDay: row.julianDay, observer: Self.sanFrancisco)
            .first { $0.id == "moon" }!
        let ndc = projector.project(direction: projector.direction(ofDate: moon.equatorial))!
        // 10 degrees across 1000 px: 36" per pixel; the Moon should be within
        // its own residual of dead centre.
        XCTAssertLessThan(simd_length(ndc) * 5 * 3600, 30)

        // Refraction lifts it, by about the tabulated amount.
        frame.refractionEnabled = true
        let refracted = SkyProjector(frameData: frame, apparentFrame: apparent)
        let liftedNDC = refracted.project(direction: refracted.direction(ofDate: moon.equatorial))!
        let expectedLift = Refraction.refractionDegrees(trueAltitudeDegrees: row.altitude!)
        // NDC y: half the vertical field is 5 degrees.
        XCTAssertEqual((liftedNDC.y - ndc.y) * 5, expectedLift, accuracy: 0.001)
    }
}

/// The Galilean satellites against Horizons (targets 501-504 and 599,
/// geocentric apparent RA/Dec, 2026-09-15 06:00 UT).
final class JupiterMoonAccuracyTests: XCTestCase {

    struct Reference { let moon: JupiterMoons.Moon; let ra: Double; let dec: Double }
    static let jupiter = (ra: 139.242943245, dec: 16.389316279, deltaAU: 6.08453010651398)
    static let references: [Reference] = [
        Reference(moon: .io, ra: 139.232328036, dec: 16.393069460),
        Reference(moon: .europa, ra: 139.205376649, dec: 16.402070778),
        Reference(moon: .ganymede, ra: 139.234419511, dec: 16.391807245),
        Reference(moon: .callisto, ra: 139.358117140, dec: 16.350385129),
    ]

    func testGalileanMoonsLandWhereHorizonsPutsThem() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let jd = JulianDate.julianDay(from: calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 15, hour: 6
        ))!)
        let jupiterEq = EquatorialCoordinate(rightAscensionDegrees: Self.jupiter.ra, declinationDegrees: Self.jupiter.dec)
        let distanceKm = Self.jupiter.deltaAU * AstronomicalConstants.astronomicalUnitKilometres
        let orientation = PlanetaryOrientation.orientation(objectID: "jupiter", equatorial: jupiterEq, julianDay: jd)!
        let poleAngle = PlanetaryOrientation.polePositionAngleDegrees(
            poleDirection: orientation.poleDirection, equatorial: jupiterEq
        )!
        let positions = JupiterMoons.positions(julianDay: jd)
        let radiusArcsec = Angle.radiansToDegrees(atan(JupiterMoons.jupiterEquatorialRadiusKm / distanceKm)) * 3600

        for reference in Self.references {
            let position = positions.first { $0.moon == reference.moon }!
            let computed = JupiterMoons.equatorial(
                of: position, jupiter: jupiterEq, jupiterDistanceKm: distanceKm,
                polePositionAngleDegrees: poleAngle
            )
            let residual = HorizonsAccuracyTests.separationArcseconds(
                computed, ra: reference.ra, dec: reference.dec
            )
            // Meeus quotes ~0.1 Jupiter radii for the lower-accuracy method.
            XCTAssertLessThan(
                residual, 0.15 * radiusArcsec,
                "\(reference.moon.name): \(residual)\" from Horizons (Jupiter radius \(radiusArcsec)\")"
            )
        }
    }
}
