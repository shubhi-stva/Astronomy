//
//  SeasonEvents.swift
//  Astronomy
//
//  Equinoxes and solstices.
//
//  Defined exactly as the IAU defines them: the instants the Sun's apparent
//  geocentric ecliptic longitude reaches 0, 90, 180 and 270 degrees. Not the
//  day the day-length crosses twelve hours (which is a different day, because
//  refraction and the Sun's diameter both add to the apparent day), and not a
//  fixed calendar date.
//
//  The names are hemisphere-dependent and this app knows where the observer is,
//  so `title(for:latitude:)` says "June solstice" in the neutral case and names
//  the season only when it can be right about it.
//
//  Accuracy: the Sun's longitude advances about 0.9856 degrees per day, so one
//  arcsecond of longitude error is 87 seconds of time. `SunPosition` implements
//  the low-precision solar series (Meeus ch. 25), quoted at about 0.01 degrees,
//  which is roughly 15 minutes of time; that is the dominant term, ΔT
//  (about 70 seconds this century, and not modelled anywhere in this app) is
//  the next. `SeasonEventTests` reports the measured residual.
//

import Foundation

enum SeasonPoint: String, CaseIterable, Sendable {
    case marchEquinox
    case juneSolstice
    case septemberEquinox
    case decemberSolstice

    /// Apparent solar ecliptic longitude at this point, in degrees.
    var solarLongitudeDegrees: Double {
        switch self {
        case .marchEquinox: return 0
        case .juneSolstice: return 90
        case .septemberEquinox: return 180
        case .decemberSolstice: return 270
        }
    }

    /// The month-based name, which is correct in both hemispheres.
    var neutralName: String {
        switch self {
        case .marchEquinox: return "March Equinox"
        case .juneSolstice: return "June Solstice"
        case .septemberEquinox: return "September Equinox"
        case .decemberSolstice: return "December Solstice"
        }
    }

    /// What the point means at a given latitude. The northern and southern
    /// hemispheres get opposite seasons, and this is one of the few places in
    /// the app where saying "summer" without checking would simply be wrong for
    /// half the planet.
    func seasonName(latitudeDegrees: Double) -> String {
        let north = latitudeDegrees >= 0
        switch self {
        case .marchEquinox: return north ? "spring begins" : "autumn begins"
        case .juneSolstice: return north ? "summer begins — longest day" : "winter begins — shortest day"
        case .septemberEquinox: return north ? "autumn begins" : "spring begins"
        case .decemberSolstice: return north ? "winter begins — shortest day" : "summer begins — longest day"
        }
    }
}

enum SeasonEvents {

    /// Bracketing step, in days. The Sun's longitude advances just under a
    /// degree a day and never reverses, so half a day is a factor of ~180
    /// inside the smallest interval (90 degrees) that could be skipped.
    static let stepDays: Double = 0.5

    static func events(
        fromJulianDay start: Double, toJulianDay end: Double, latitudeDegrees: Double
    ) -> [AstronomicalEvent] {
        var events: [AstronomicalEvent] = []
        for point in SeasonPoint.allCases {
            let times = EventSolver.crossings(
                of: EclipticLongitude.sunOfDate(julianDay:),
                targetDegrees: point.solarLongitudeDegrees,
                from: start, to: end, stepDays: stepDays
            )
            for time in times {
                events.append(
                    event(point: point, julianDay: time, latitudeDegrees: latitudeDegrees)
                )
            }
        }
        return events.sorted { $0.julianDay < $1.julianDay }
    }

    static func event(
        point: SeasonPoint, julianDay: Double, latitudeDegrees: Double
    ) -> AstronomicalEvent {
        AstronomicalEvent(
            id: "season-\(point.rawValue)-\(Int(julianDay))",
            kind: .season,
            provenance: .computed,
            julianDay: julianDay,
            title: point.neutralName,
            detail: "The Sun's apparent longitude reaches \(Int(point.solarLongitudeDegrees))° — \(point.seasonName(latitudeDegrees: latitudeDegrees)).",
            targetObjectID: "sun",
            // Deliberately no target position: the interesting thing about an
            // equinox is not where the Sun is at that instant, and pointing the
            // camera at it would be pointing at daylight.
            targetEquatorial: nil
        )
    }
}
