//
//  CloseApproachEvents.swift
//  Astronomy
//
//  Pairings: two bright bodies close together in the sky.
//
//  These are the events people actually go outside for, and they are also the
//  ones a calendar most easily fills with noise, because the Moon passes every
//  planet every month. Three filters keep the list to things worth a look:
//
//   1. **Separation.** Only minima closer than `maximumSeparationDegrees`. A
//      naked eye reads two objects as "together" at a few degrees; beyond about
//      five they are simply two objects in the same part of the sky.
//   2. **Elongation from the Sun.** A pairing 8 degrees from the Sun is
//      geometrically real and observationally fictional. Below
//      `minimumSolarElongationDegrees` it is dropped.
//   3. **Brightness.** Only the bodies visible without optical aid: the Moon,
//      and the five classical planets. Uranus and Neptune are excluded from the
//      pairing list — a Neptune conjunction is a telescopic event, and putting
//      it in a "look up tonight" list would be misleading.
//
//  Both members are always named, and the printed separation is the minimum
//  itself rather than the separation at some rounded hour, because a conjunction
//  quoted at 0.9 degrees that is 2.4 degrees when you look is worse than useless.
//

import Foundation

/// The naked-eye bodies the pairing search runs over.
enum BrightBody: String, CaseIterable, Sendable {
    case moon, mercury, venus, mars, jupiter, saturn

    var displayName: String {
        switch self {
        case .moon: return "Moon"
        default: return Planet(rawValue: rawValue)?.displayName ?? rawValue.capitalized
        }
    }

    /// The `CelestialObject.id` the rest of the app knows this body by.
    var objectID: String { rawValue }

    func equatorial(julianDay jd: Double) -> EquatorialCoordinate {
        if self == .moon { return MoonPosition.equatorialCoordinate(julianDay: jd) }
        guard let planet = Planet(rawValue: rawValue) else {
            return MoonPosition.equatorialCoordinate(julianDay: jd)
        }
        return PlanetPosition.equatorialCoordinate(planet: planet, julianDay: jd)
    }
}

enum CloseApproachEvents {

    /// Reported only below this. See the note above on why five degrees.
    static let maximumSeparationDegrees: Double = 5.0

    /// Pairings closer to the Sun than this are dropped as unobservable.
    static let minimumSolarElongationDegrees: Double = 15.0

    /// Bracketing step for a pair including the Moon, in days.
    ///
    /// The Moon moves 13.2 degrees a day against the stars, so a quarter of a
    /// day is 3.3 degrees — comfortably finer than the 5-degree window a
    /// reportable approach has to be caught inside, which is the condition for
    /// not missing one entirely.
    static let lunarStepDays: Double = 0.25

    /// Bracketing step for two planets. The fastest relative motion here is
    /// Mercury's, at up to about 2 degrees a day, so a day is the same factor
    /// of safety at a quarter of the cost.
    static let planetaryStepDays: Double = 1.0

    static func events(
        fromJulianDay start: Double, toJulianDay end: Double
    ) -> [AstronomicalEvent] {
        var events: [AstronomicalEvent] = []
        let bodies = BrightBody.allCases

        for (i, first) in bodies.enumerated() {
            for second in bodies.dropFirst(i + 1) {
                let involvesMoon = first == .moon || second == .moon
                let separation: (Double) -> Double = { jd in
                    VisibilityRating.angularSeparationDegrees(
                        first.equatorial(julianDay: jd), second.equatorial(julianDay: jd)
                    )
                }
                let minima = EventSolver.localMinima(
                    of: separation, from: start, to: end,
                    stepDays: involvesMoon ? lunarStepDays : planetaryStepDays
                )
                for minimum in minima where minimum.value <= maximumSeparationDegrees {
                    guard let event = event(
                        first: first, second: second,
                        julianDay: minimum.julianDay, separationDegrees: minimum.value
                    ) else { continue }
                    events.append(event)
                }
            }
        }
        return events.sorted { $0.julianDay < $1.julianDay }
    }

    /// Builds the event, or returns nil when the pairing is too close to the
    /// Sun to be seen.
    static func event(
        first: BrightBody, second: BrightBody, julianDay: Double, separationDegrees: Double
    ) -> AstronomicalEvent? {
        let a = first.equatorial(julianDay: julianDay)
        let b = second.equatorial(julianDay: julianDay)
        let sun = SunPosition.equatorialCoordinate(julianDay: julianDay)
        let elongation = min(
            VisibilityRating.angularSeparationDegrees(sun, a),
            VisibilityRating.angularSeparationDegrees(sun, b)
        )
        guard elongation >= minimumSolarElongationDegrees else { return nil }

        // The midpoint of the pair is where to point the camera — pointing at
        // either member would put the other at the edge of a narrow field.
        let midpoint = EquatorialCoordinate(
            rightAscensionDegrees: Angle.normalizeDegrees(
                a.rightAscensionDegrees
                    + EventSolver.signedDelta(b.rightAscensionDegrees, a.rightAscensionDegrees) / 2
            ),
            declinationDegrees: (a.declinationDegrees + b.declinationDegrees) / 2
        )
        let separationText = separationDegrees < 1
            ? "\((separationDegrees * 60).formatted(.number.precision(.fractionLength(0))))′"
            : "\(separationDegrees.formatted(.number.precision(.fractionLength(1))))°"

        return AstronomicalEvent(
            id: "approach-\(first.rawValue)-\(second.rawValue)-\(Int(julianDay))",
            kind: .closeApproach,
            provenance: .computed,
            julianDay: julianDay,
            title: "\(first.displayName) meets \(second.displayName)",
            detail: "Closest approach: \(separationText) apart, \(Int(elongation.rounded()))° from the Sun.",
            // Selecting the pair is meaningless, so the target is the slower of
            // the two — the one that will still be roughly there tomorrow.
            targetObjectID: first == .moon ? second.objectID : first.objectID,
            targetEquatorial: midpoint
        )
    }
}
