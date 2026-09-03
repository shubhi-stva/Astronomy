//
//  MoonPhaseEvents.swift
//  Astronomy
//
//  The four principal lunar phases, solved rather than tabulated.
//
//  A phase is defined by geometry, not by appearance: new moon is the instant
//  the Moon's apparent ecliptic longitude equals the Sun's, and the quarters
//  and the full moon are the same equality offset by 90, 180 and 270 degrees.
//  So the whole computation is one root find on `moonElongationOfDate`, which
//  is why this file is short.
//
//  Accuracy is bounded by the ephemerides, not by the solver. The elongation
//  changes by about 12.19 degrees per day — 0.5 degrees per hour — so an error
//  of one arcminute in the Moon's longitude is an error of about two minutes in
//  the time of the phase. The truncated ELP series in `MoonPosition` is good to
//  a few arcminutes, and no ΔT correction is applied anywhere in this app, so
//  these times should be trusted to a handful of minutes and no better.
//  `MoonPhaseEventTests` measures the residual against Meeus's worked examples
//  rather than asserting a precision nobody checked.
//

import Foundation

enum PrincipalMoonPhase: String, CaseIterable, Sendable {
    case newMoon
    case firstQuarter
    case fullMoon
    case lastQuarter

    /// Moon-minus-Sun ecliptic longitude at this phase, in degrees.
    var elongationDegrees: Double {
        switch self {
        case .newMoon: return 0
        case .firstQuarter: return 90
        case .fullMoon: return 180
        case .lastQuarter: return 270
        }
    }

    var displayName: String {
        switch self {
        case .newMoon: return "New Moon"
        case .firstQuarter: return "First Quarter"
        case .fullMoon: return "Full Moon"
        case .lastQuarter: return "Last Quarter"
        }
    }
}

enum MoonPhaseEvents {

    /// Bracketing step, in days.
    ///
    /// The elongation advances monotonically at 11.8 to 14.9 degrees per day —
    /// it never reverses, because the Moon's mean motion dominates every
    /// perturbation in the series — so the only requirement is that a step
    /// cannot skip a 90-degree interval. A quarter of a day is at most 3.7
    /// degrees, a factor of 24 inside that, and costs four evaluations a day.
    static let stepDays: Double = 0.25

    /// Every principal phase in `[start, end]`, in time order.
    static func events(fromJulianDay start: Double, toJulianDay end: Double) -> [AstronomicalEvent] {
        var events: [AstronomicalEvent] = []
        for phase in PrincipalMoonPhase.allCases {
            let times = EventSolver.crossings(
                of: EclipticLongitude.moonElongationOfDate(julianDay:),
                targetDegrees: phase.elongationDegrees,
                from: start, to: end, stepDays: stepDays
            )
            for time in times {
                events.append(event(phase: phase, julianDay: time))
            }
        }
        return events.sorted { $0.julianDay < $1.julianDay }
    }

    static func event(phase: PrincipalMoonPhase, julianDay: Double) -> AstronomicalEvent {
        let moon = MoonPosition.equatorialCoordinate(julianDay: julianDay)
        let distance = MoonPosition.distanceKilometres(julianDay: julianDay)
        return AstronomicalEvent(
            id: "moon-phase-\(phase.rawValue)-\(Int(julianDay * 1440))",
            kind: .moonPhase,
            provenance: .computed,
            julianDay: julianDay,
            title: phase.displayName,
            detail: detail(phase: phase, distanceKilometres: distance),
            targetObjectID: "moon",
            targetEquatorial: moon
        )
    }

    /// The distance is the part worth printing. A full moon within about
    /// 360,000 km is what the press calls a supermoon; a new moon's distance is
    /// what decides whether the following evening's crescent is easy or not.
    private static func detail(phase: PrincipalMoonPhase, distanceKilometres d: Double) -> String {
        let rounded = (d / 1000).rounded() * 1000
        let distanceText = "\(Int(rounded).formatted()) km away"
        switch phase {
        case .newMoon:
            return "Moon between Earth and Sun — the darkest skies of the month. \(distanceText)."
        case .firstQuarter:
            return "Half lit and highest at sunset. Best crater shadows along the terminator. \(distanceText)."
        case .fullMoon:
            return "Opposite the Sun, up all night, and bright enough to wash out everything faint. \(distanceText)."
        case .lastQuarter:
            return "Half lit, rising near midnight — the evening sky is dark again. \(distanceText)."
        }
    }
}
