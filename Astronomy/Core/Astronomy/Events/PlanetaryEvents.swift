//
//  PlanetaryEvents.swift
//  Astronomy
//
//  Oppositions, conjunctions and greatest elongations, solved from the same
//  planetary ephemeris the sky is drawn from.
//
//  All three are extrema of one quantity: the geocentric elongation, the angle
//  Sun–Earth–planet. A superior planet's elongation reaches 180 degrees at
//  opposition and 0 at conjunction; an inferior planet's never reaches 180 at
//  all, and its maxima are the greatest elongations (28 degrees for Mercury, 47
//  for Venus) that decide when it is worth looking for at all.
//
//  Two conjunctions of an inferior planet are distinguished by distance rather
//  than by angle, because in angle they are identical: at inferior conjunction
//  the planet passes between Earth and Sun and is *nearer* than the Sun; at
//  superior conjunction it is behind the Sun and further. The geocentric
//  distance `PlanetPosition.state` already returns settles it in one comparison.
//
//  ACCURACY. `PlanetPosition` uses linear Keplerian elements (the JPL
//  approximate-positions table), which is good to roughly an arcminute for the
//  inner planets and a few arcminutes for the outer ones over this app's
//  1800–2050 window. Near opposition a superior planet's elongation changes
//  slowly — that is what makes an opposition a *maximum* — so a few arcminutes
//  of position error becomes a few hours of timing error. These dates are
//  right; the times of day are approximate, and the UI says so by printing
//  oppositions to the day rather than to the minute.
//

import Foundation

enum PlanetaryEvents {

    /// Bracketing step, in days.
    ///
    /// Chosen against Mercury, whose synodic period is 116 days and which
    /// therefore runs through its whole elongation cycle four times faster than
    /// anything else here — roughly 30 days between a greatest elongation and
    /// the next conjunction. A two-day grid puts fifteen samples across that,
    /// which brackets every extremum with room to spare; the outer planets are
    /// oversampled by an order of magnitude and cost nothing extra worth
    /// measuring.
    static let stepDays: Double = 2.0

    /// A maximum this close to 180 degrees is an opposition rather than merely
    /// the best a planet managed that cycle.
    static let oppositionThresholdDegrees: Double = 150

    /// A minimum inside this is a conjunction with the Sun. Wide enough to
    /// catch the outer planets, whose elongation minimum does not reach zero
    /// exactly because their orbits are inclined.
    static let conjunctionThresholdDegrees: Double = 12

    /// Elongation of a planet from the Sun, in degrees, at an instant.
    static func elongationDegrees(planet: Planet, julianDay jd: Double) -> Double {
        VisibilityRating.angularSeparationDegrees(
            SunPosition.equatorialCoordinate(julianDay: jd),
            PlanetPosition.equatorialCoordinate(planet: planet, julianDay: jd)
        )
    }

    /// True when the planet is east of the Sun — i.e. sets after it, and is
    /// therefore an evening object. The distinction that makes a greatest
    /// elongation actionable.
    static func isEastOfSun(planet: Planet, julianDay jd: Double) -> Bool {
        let planetLongitude = EclipticLongitude.ofDate(
            equatorialOfDate: PlanetPosition.equatorialCoordinate(planet: planet, julianDay: jd),
            julianDay: jd
        )
        let sunLongitude = EclipticLongitude.sunOfDate(julianDay: jd)
        return EventSolver.signedDelta(planetLongitude, sunLongitude) > 0
    }

    static func events(
        fromJulianDay start: Double, toJulianDay end: Double
    ) -> [AstronomicalEvent] {
        var events: [AstronomicalEvent] = []
        for planet in Planet.allCases {
            let elongation = { elongationDegrees(planet: planet, julianDay: $0) }

            for maximum in EventSolver.localMaxima(
                of: elongation, from: start, to: end, stepDays: stepDays
            ) {
                if maximum.value >= oppositionThresholdDegrees {
                    events.append(opposition(planet: planet, julianDay: maximum.julianDay))
                } else if planet == .mercury || planet == .venus {
                    events.append(
                        greatestElongation(
                            planet: planet, julianDay: maximum.julianDay,
                            elongationDegrees: maximum.value
                        )
                    )
                }
            }

            for minimum in EventSolver.localMinima(
                of: elongation, from: start, to: end, stepDays: stepDays
            ) where minimum.value <= conjunctionThresholdDegrees {
                events.append(
                    solarConjunction(
                        planet: planet, julianDay: minimum.julianDay,
                        elongationDegrees: minimum.value
                    )
                )
            }
        }
        return events.sorted { $0.julianDay < $1.julianDay }
    }

    // MARK: - Constructors

    private static func opposition(planet: Planet, julianDay: Double) -> AstronomicalEvent {
        let state = PlanetPosition.state(planet: planet, julianDay: julianDay)
        let distance = state.geocentricDistanceAU
        return AstronomicalEvent(
            id: "opposition-\(planet.rawValue)-\(Int(julianDay))",
            kind: .opposition,
            provenance: .computed,
            julianDay: julianDay,
            title: "\(planet.displayName) at opposition",
            detail: "Opposite the Sun: rises at sunset, sets at sunrise, and is at its closest and brightest for this cycle — \(distance.formatted(.number.precision(.fractionLength(2)))) AU away.",
            targetObjectID: planet.rawValue,
            targetEquatorial: state.equatorial
        )
    }

    private static func greatestElongation(
        planet: Planet, julianDay: Double, elongationDegrees: Double
    ) -> AstronomicalEvent {
        let east = isEastOfSun(planet: planet, julianDay: julianDay)
        let side = east ? "east" : "west"
        let when = east ? "in the evening sky after sunset" : "in the morning sky before sunrise"
        return AstronomicalEvent(
            id: "elongation-\(planet.rawValue)-\(Int(julianDay))",
            kind: .greatestElongation,
            provenance: .computed,
            julianDay: julianDay,
            title: "\(planet.displayName) at greatest \(side)ern elongation",
            detail: "\(elongationDegrees.formatted(.number.precision(.fractionLength(1))))° from the Sun — as far as it gets this cycle, and the easiest it will be to find \(when).",
            targetObjectID: planet.rawValue,
            targetEquatorial: PlanetPosition.equatorialCoordinate(
                planet: planet, julianDay: julianDay
            )
        )
    }

    private static func solarConjunction(
        planet: Planet, julianDay: Double, elongationDegrees: Double
    ) -> AstronomicalEvent {
        let state = PlanetPosition.state(planet: planet, julianDay: julianDay)
        let sunDistance = SunPosition.radiusVectorAU(julianDay: julianDay)
        let isInferior = (planet == .mercury || planet == .venus)
            && state.geocentricDistanceAU < sunDistance
        let qualifier = isInferior ? "inferior " : (planet == .mercury || planet == .venus ? "superior " : "")
        return AstronomicalEvent(
            id: "solar-conjunction-\(planet.rawValue)-\(Int(julianDay))",
            kind: .conjunction,
            provenance: .computed,
            julianDay: julianDay,
            title: "\(planet.displayName) at \(qualifier)conjunction",
            detail: "Only \(elongationDegrees.formatted(.number.precision(.fractionLength(1))))° from the Sun and lost in its glare. Not observable — listed so the gap in \(planet.displayName)'s season is accounted for.",
            targetObjectID: planet.rawValue,
            targetEquatorial: state.equatorial
        )
    }
}
