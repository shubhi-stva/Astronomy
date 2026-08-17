//
//  JulianDate.swift
//  Astronomy
//
//  Pure calculation utilities for converting between `Date` and Julian Date /
//  Julian Century — the time representation used throughout the astronomy
//  calculation layer. No SwiftUI or Metal imports: this file is unit testable
//  in isolation.
//
//  Reference: Jean Meeus, "Astronomical Algorithms", 2nd ed., Chapter 7.
//

import Foundation

enum JulianDate {

    /// Converts a `Date` (assumed UTC, as all `Date` values are) to a Julian Date.
    ///
    /// Uses the standard Meeus algorithm (Astronomical Algorithms, Ch. 7).
    static func julianDay(from date: Date) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date
        )

        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return 0
        }

        let hour = Double(components.hour ?? 0)
        let minute = Double(components.minute ?? 0)
        let second = Double(components.second ?? 0)
        let nanosecond = Double(components.nanosecond ?? 0)

        let dayFraction = (hour + minute / 60.0 + second / 3600.0 + nanosecond / 3_600_000_000_000.0) / 24.0
        let dayWithFraction = Double(day) + dayFraction

        var y = year
        var m = month
        if m <= 2 {
            y -= 1
            m += 12
        }

        let a = Int(floor(Double(y) / 100.0))
        // Gregorian calendar correction (valid for all dates we care about, post-1582).
        let b = 2 - a + Int(floor(Double(a) / 4.0))

        let jd = floor(365.25 * Double(y + 4716))
            + floor(30.6001 * Double(m + 1))
            + dayWithFraction
            + Double(b)
            - 1524.5

        return jd
    }

    /// Julian Date for the standard J2000.0 epoch (2000 January 1, 12:00 TT).
    static let j2000: Double = 2_451_545.0

    /// Number of Julian centuries since J2000.0 for the given Julian Day.
    static func julianCenturies(fromJulianDay jd: Double) -> Double {
        (jd - j2000) / 36525.0
    }

    /// Convenience: Julian centuries since J2000.0 for a `Date`.
    static func julianCenturies(from date: Date) -> Double {
        julianCenturies(fromJulianDay: julianDay(from: date))
    }

    /// Reconstructs a `Date` from a Julian Day number (UTC).
    static func date(fromJulianDay jd: Double) -> Date {
        let referenceJD = j2000
        let secondsPerDay = 86400.0
        let referenceDate = Date(timeIntervalSince1970: 946_728_000) // 2000-01-01 12:00 UTC
        let deltaDays = jd - referenceJD
        return referenceDate.addingTimeInterval(deltaDays * secondsPerDay)
    }
}
