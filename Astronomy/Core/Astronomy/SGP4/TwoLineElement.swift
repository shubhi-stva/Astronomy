//
//  TwoLineElement.swift
//  Astronomy
//
//  Parser for NORAD two-line element sets (TLEs).
//
//  The column layout is the one fixed by the US Space Force / Space-Track
//  format and reproduced in Vallado et al., "Revisiting Spacetrack Report #3",
//  AIAA 2006-6753. Fields are read by *column*, not by whitespace splitting:
//  several fields (the international designator, the drag term) can legally
//  run together or contain embedded blanks, so tokenising on spaces gives the
//  wrong answer on real catalogue data.
//
//  Two field encodings deserve a note, because neither is ordinary text:
//
//   * The eccentricity has an *implied* leading decimal point: "0006703" means
//     0.0006703.
//   * `nddot` and `bstar` use the "modified exponential" form " 12345-3",
//     meaning 0.12345e-3, with the mantissa's decimal point implied and the
//     exponent written as a bare signed digit.
//
//  Satellite numbers may also be in "Alpha-5" form once the catalogue passed
//  99999: the leading digit becomes a letter, A=10 ... Z=33, skipping I and O
//  to avoid confusion with 1 and 0. That is decoded here so a modern
//  catalogue's NORAD IDs come out as plain integers.
//

import Foundation

/// One parsed TLE: the object's name plus the orbital elements, still in the
/// units the TLE itself uses (degrees, revolutions per day).
struct TwoLineElement: Hashable, Sendable {

    /// Object name from the (optional) title line, e.g. "ISS (ZARYA)".
    var name: String
    /// NORAD catalog number, Alpha-5 decoded.
    var catalogNumber: Int
    /// International designator ("98067A"), trimmed. Empty when absent.
    var internationalDesignator: String

    /// Two-digit epoch year as written in the element set.
    var epochYear: Int
    /// Day of year (1.0 = Jan 1 00:00 UTC) plus fractional day.
    var epochDayOfYear: Double

    /// First derivative of mean motion / 2, in revolutions per day squared.
    var meanMotionDot: Double
    /// Second derivative of mean motion / 6, in revolutions per day cubed.
    var meanMotionDDot: Double
    /// SGP4 drag term, in inverse Earth radii.
    var bstar: Double

    var inclinationDegrees: Double
    var rightAscensionOfAscendingNodeDegrees: Double
    var eccentricity: Double
    var argumentOfPerigeeDegrees: Double
    var meanAnomalyDegrees: Double
    /// Mean motion in revolutions per day (Kozai/Brouwer mean element).
    var meanMotionRevsPerDay: Double
    var revolutionNumber: Int
    var elementSetNumber: Int

    /// Four-digit epoch year. The TLE format carries only two digits, so the
    /// standard 1957-2056 windowing rule applies (Vallado's `twoline2rv`).
    var fullEpochYear: Int { epochYear < 57 ? epochYear + 2000 : epochYear + 1900 }

    /// Julian Day of the element-set epoch (UTC, treated as UT1 — see
    /// `SGP4Propagator` for why that approximation is acceptable here).
    var epochJulianDay: Double {
        let (month, day, hour, minute, second) = Self.monthDayHMS(
            year: fullEpochYear, dayOfYear: epochDayOfYear
        )
        return Self.julianDay(
            year: fullEpochYear, month: month, day: day,
            hour: hour, minute: minute, second: second
        )
    }

    /// Days since 1949 December 31 00:00 UT — the "SGP4 epoch" the propagator
    /// initialises against. `2433281.5` is that instant's Julian Day.
    var sgp4Epoch: Double { epochJulianDay - 2433281.5 }

    /// Orbital period in minutes, from the mean motion as written.
    var periodMinutes: Double {
        meanMotionRevsPerDay > 0 ? 1440.0 / meanMotionRevsPerDay : .infinity
    }
}

// MARK: - Parsing

extension TwoLineElement {

    /// Parses a single element set from its two data lines, plus an optional
    /// title line. Returns nil if the lines are malformed.
    static func parse(name: String?, line1: String, line2: String) -> TwoLineElement? {
        let l1 = Array(line1.utf8)
        let l2 = Array(line2.utf8)
        // 69 is the canonical record length; some sources pad or trim the
        // trailing checksum, so require only enough columns for every field we
        // actually read.
        guard l1.count >= 68, l2.count >= 63 else { return nil }
        guard l1[0] == UInt8(ascii: "1"), l2[0] == UInt8(ascii: "2") else { return nil }

        guard let catalogNumber = alpha5Number(l1, 2, 7),
              let epochYear = intField(l1, 18, 20),
              let epochDay = doubleField(l1, 20, 32),
              let ndot = doubleField(l1, 33, 43),
              let nddot = exponentialField(l1, 44, 52),
              let bstar = exponentialField(l1, 53, 61),
              let inclination = doubleField(l2, 8, 16),
              let raan = doubleField(l2, 17, 25),
              let eccentricityDigits = doubleField(l2, 26, 33),
              let argp = doubleField(l2, 34, 42),
              let meanAnomaly = doubleField(l2, 43, 51),
              let meanMotion = doubleField(l2, 52, 63)
        else { return nil }

        let designator = string(l1, 9, 17).trimmingCharacters(in: .whitespaces)
        let elementSetNumber = intField(l1, 64, 68) ?? 0
        let revolutionNumber = l2.count >= 68 ? (intField(l2, 63, 68) ?? 0) : 0

        return TwoLineElement(
            name: name?.trimmingCharacters(in: .whitespaces) ?? "\(catalogNumber)",
            catalogNumber: catalogNumber,
            internationalDesignator: designator,
            epochYear: epochYear,
            epochDayOfYear: epochDay,
            meanMotionDot: ndot,
            meanMotionDDot: nddot,
            bstar: bstar,
            inclinationDegrees: inclination,
            rightAscensionOfAscendingNodeDegrees: raan,
            // Implied leading decimal point.
            eccentricity: eccentricityDigits * 1e-7,
            argumentOfPerigeeDegrees: argp,
            meanAnomalyDegrees: meanAnomaly,
            meanMotionRevsPerDay: meanMotion,
            revolutionNumber: revolutionNumber,
            elementSetNumber: elementSetNumber
        )
    }

    /// Parses a whole TLE file: repeating (optional name, line 1, line 2)
    /// records. Records that fail to parse are skipped rather than aborting the
    /// file — one corrupt entry in a 16,000-object catalogue must not cost the
    /// other 15,999.
    static func parseCatalog(_ text: String) -> [TwoLineElement] {
        var results: [TwoLineElement] = []
        results.reserveCapacity(20_000)

        var pendingName: String?
        var pendingLine1: String?

        text.enumerateLines { rawLine, _ in
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }

            if line.hasPrefix("1 ") {
                pendingLine1 = line
            } else if line.hasPrefix("2 "), let line1 = pendingLine1 {
                if let element = parse(name: pendingName, line1: line1, line2: line) {
                    results.append(element)
                }
                pendingLine1 = nil
                pendingName = nil
            } else {
                // Title line. Any leftover half-record is abandoned.
                pendingName = line
                pendingLine1 = nil
            }
        }
        return results
    }

    // MARK: Field readers

    private static func string(_ bytes: [UInt8], _ from: Int, _ to: Int) -> String {
        guard from < bytes.count else { return "" }
        let end = min(to, bytes.count)
        return String(decoding: bytes[from..<end], as: UTF8.self)
    }

    private static func doubleField(_ bytes: [UInt8], _ from: Int, _ to: Int) -> Double? {
        let text = string(bytes, from, to).trimmingCharacters(in: .whitespaces)
        // A blank first-derivative field is legal and means zero.
        if text.isEmpty { return 0 }
        return Double(text)
    }

    private static func intField(_ bytes: [UInt8], _ from: Int, _ to: Int) -> Int? {
        let text = string(bytes, from, to).trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return nil }
        return Int(text)
    }

    /// The "modified exponential" fields: an optionally signed 5-digit mantissa
    /// with an implied leading decimal point, followed by a signed exponent.
    /// " 12345-3" is 0.12345e-3; " 00000+0" and "        " are both zero.
    private static func exponentialField(_ bytes: [UInt8], _ from: Int, _ to: Int) -> Double? {
        let text = string(bytes, from, to).trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return 0 }

        var mantissaText = text
        var sign = 1.0
        if mantissaText.hasPrefix("-") {
            sign = -1
            mantissaText.removeFirst()
        } else if mantissaText.hasPrefix("+") {
            mantissaText.removeFirst()
        }

        // Split at the *exponent* sign, which is the last +/- in the field.
        var exponent = 0
        if let signIndex = mantissaText.lastIndex(where: { $0 == "+" || $0 == "-" }) {
            let exponentText = String(mantissaText[signIndex...])
            guard let value = Int(exponentText) else { return nil }
            exponent = value
            mantissaText = String(mantissaText[..<signIndex])
        }

        if mantissaText.isEmpty { return 0 }
        // Some producers write an explicit decimal point; honour it if present.
        let mantissa: Double
        if mantissaText.contains(".") {
            guard let value = Double(mantissaText) else { return nil }
            mantissa = value
        } else {
            guard let digits = Double(mantissaText) else { return nil }
            mantissa = digits * pow(10.0, -Double(mantissaText.count))
        }
        return sign * mantissa * pow(10.0, Double(exponent))
    }

    /// Decodes an Alpha-5 satellite number. Plain numeric IDs pass through.
    private static func alpha5Number(_ bytes: [UInt8], _ from: Int, _ to: Int) -> Int? {
        let text = string(bytes, from, to).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if let plain = Int(text) { return plain }

        guard let first = text.first, first.isLetter else { return nil }
        // A=10 ... Z=33, skipping I and O.
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
        guard let index = alphabet.firstIndex(of: Character(first.uppercased())) else { return nil }
        guard let remainder = Int(text.dropFirst()) else { return nil }
        return (index + 10) * 10_000 + remainder
    }

    // MARK: Calendar helpers

    /// Vallado's `days2mdhms_SGP4`, ported directly. Note the leap-year test is
    /// the simple `year % 4` one the reference uses — correct for the entire
    /// 1957-2056 window a two-digit TLE year can express.
    static func monthDayHMS(
        year: Int, dayOfYear: Double
    ) -> (month: Int, day: Int, hour: Int, minute: Int, second: Double) {
        var lmonth = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        if year % 4 == 0 { lmonth[2] = 29 }

        let intDayOfYear = Int(floor(dayOfYear))
        var i = 1
        var accumulated = 0
        while i < 12 && intDayOfYear > accumulated + lmonth[i] {
            accumulated += lmonth[i]
            i += 1
        }
        let month = i
        let day = intDayOfYear - accumulated

        var temp = (dayOfYear - Double(intDayOfYear)) * 24.0
        let hour = Int(floor(temp))
        temp = (temp - Double(hour)) * 60.0
        let minute = Int(floor(temp))
        let second = (temp - Double(minute)) * 60.0

        return (month, day, hour, minute, second)
    }

    /// Vallado's `jday_SGP4`, ported directly. Kept separate from the app's own
    /// `JulianDate` so the SGP4 epoch is computed by exactly the algorithm the
    /// reference implementation uses — the verification vectors are stated
    /// relative to it.
    static func julianDay(
        year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Double
    ) -> Double {
        let jd = 367.0 * Double(year)
            - floor((7.0 * (Double(year) + floor((Double(month) + 9.0) / 12.0))) * 0.25)
            + floor(275.0 * Double(month) / 9.0)
            + Double(day) + 1_721_013.5
        let jdFrac = (second + Double(minute) * 60.0 + Double(hour) * 3600.0) / 86_400.0
        return jd + jdFrac
    }
}
