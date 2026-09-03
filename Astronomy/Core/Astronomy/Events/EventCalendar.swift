//
//  EventCalendar.swift
//  Astronomy
//
//  Assembles the sky calendar and answers "can I actually see this from here?"
//
//  The answer deliberately reuses the machinery the Tonight dashboard already
//  runs on — `TonightPlanner.nightWindow` for the darkness, `RiseSetCalculator`
//  for the altitude curve, `VisibilityRating.altitudeBand` for the verdict —
//  rather than inventing a second, subtly different notion of "observable".
//  Two models of visibility in one app is two models that disagree in front of
//  the user.
//
//  Ranking is chronological, because a calendar that reordered itself by
//  interest would be a feed, and the question a calendar answers is "what is
//  coming". Interest is expressed instead as a *filter* (`observableOnly`) and
//  as the band shown on each row, so a spectacular event below the horizon is
//  visibly marked rather than silently promoted or hidden.
//

import Foundation

enum EventCalendar {

    /// How far ahead the calendar looks by default, in days.
    ///
    /// Three months: long enough to contain at least one of everything — three
    /// lunations, a season change, usually a meteor shower and an opposition —
    /// and short enough that the whole search is a few hundred milliseconds of
    /// closed-form ephemeris evaluation on a background task.
    static let defaultWindowDays: Double = 90

    /// Everything happening in `[start, start + days]`, in time order, each row
    /// annotated with what it looks like from `observer`.
    static func events(
        fromJulianDay start: Double,
        days: Double = defaultWindowDays,
        observer: GeographicLocation
    ) -> [AstronomicalEvent] {
        let end = start + days
        var events: [AstronomicalEvent] = []
        events += MoonPhaseEvents.events(fromJulianDay: start, toJulianDay: end)
        events += SeasonEvents.events(
            fromJulianDay: start, toJulianDay: end,
            latitudeDegrees: observer.latitudeDegrees
        )
        events += PlanetaryEvents.events(fromJulianDay: start, toJulianDay: end)
        events += CloseApproachEvents.events(fromJulianDay: start, toJulianDay: end)
        events += MeteorShowers.events(fromJulianDay: start, toJulianDay: end)

        return events
            .map { event in
                var annotated = event
                annotated.observability = observability(for: event, observer: observer)
                return annotated
            }
            .sorted { $0.julianDay < $1.julianDay }
    }

    /// The next event of a given kind after `julianDay`, for the command
    /// palette's "next full moon" style commands.
    ///
    /// Searched over a window rather than the default one so a query for a
    /// season point cannot come back empty in November.
    static func next(
        kind: AstronomicalEventKind,
        matching predicate: (AstronomicalEvent) -> Bool = { _ in true },
        afterJulianDay julianDay: Double,
        observer: GeographicLocation,
        withinDays: Double = 400
    ) -> AstronomicalEvent? {
        events(fromJulianDay: julianDay, days: withinDays, observer: observer)
            .first { $0.kind == kind && $0.julianDay > julianDay && predicate($0) }
    }

    // MARK: - Observability

    /// Interval, in days, used to scan the dark window for the target's peak
    /// altitude. Five minutes — the same step `TonightPlanner` uses for its own
    /// darkness statistics, so the two agree on where a peak is.
    static let darkScanStepDays: Double = 5.0 / 1440.0

    /// How the event's target behaves for this observer, or nil when the event
    /// has nothing to point at (an equinox) or nothing observable to say.
    static func observability(
        for event: AstronomicalEvent, observer: GeographicLocation
    ) -> EventObservability? {
        guard let position = positionFunction(for: event) else { return nil }

        let altitude: (Double) -> Double = { jd in
            CoordinateTransformService.horizontal(
                from: position(jd), observer: observer, julianDay: jd
            ).altitudeDegrees
        }

        let anchor = TonightPlanner.anchorJulianDay(
            observer: observer, julianDay: event.julianDay
        )
        let solved = RiseSetCalculator.solve(
            altitudeDegrees: altitude,
            standardAltitudeDegrees: RiseSetCalculator.StandardAltitude.point,
            startJulianDay: anchor,
            durationDays: 1
        )

        let night = TonightPlanner.nightWindow(observer: observer, julianDay: event.julianDay)
        var peakJulianDay = solved.transitJulianDay
        var peakAltitude = solved.transitAltitudeDegrees
        var peakInDarkness = false

        if let dark = night.darkWindow {
            var bestTime = dark.lowerBound
            var best = -Double.infinity
            var time = dark.lowerBound
            while time <= dark.upperBound {
                let value = altitude(time)
                if value > best {
                    best = value
                    bestTime = time
                }
                time += darkScanStepDays
            }
            if best > -Double.infinity {
                peakJulianDay = bestTime
                peakAltitude = best
                peakInDarkness = true
            }
        }

        return EventObservability(
            altitudeAtEventDegrees: altitude(event.julianDay),
            peakAltitudeDegrees: peakAltitude,
            peakJulianDay: peakJulianDay,
            circumstance: solved.circumstance,
            peakIsInDarkness: peakInDarkness,
            band: VisibilityRating.altitudeBand(peakAltitudeDegrees: peakAltitude)
        )
    }

    /// How to find the event's target at an arbitrary instant.
    ///
    /// A moving body gets its own ephemeris rather than the position frozen at
    /// the event: the Moon travels 13 degrees a night, so freezing it would put
    /// its "peak altitude tonight" out by most of an hour of hour angle. A
    /// meteor radiant, or the midpoint of a pairing, is a fixed direction and
    /// is used as given.
    static func positionFunction(
        for event: AstronomicalEvent
    ) -> ((Double) -> EquatorialCoordinate)? {
        switch event.targetObjectID {
        case "moon":
            return MoonPosition.equatorialCoordinate(julianDay:)
        case "sun":
            // The Sun is never "observable" in the sense this rating means, and
            // a season event has nothing to point at anyway.
            return nil
        case let id? where Planet(rawValue: id) != nil:
            let planet = Planet(rawValue: id)!
            return { PlanetPosition.equatorialCoordinate(planet: planet, julianDay: $0) }
        default:
            guard let fixed = event.targetEquatorial else { return nil }
            return { _ in fixed }
        }
    }
}
