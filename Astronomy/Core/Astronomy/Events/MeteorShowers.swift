//
//  MeteorShowers.swift
//  Astronomy
//
//  The one part of the calendar that is NOT computed.
//
//  A meteor shower's maximum is not derivable from the ephemerides in this app,
//  or from any ephemeris: it is the moment Earth passes through the densest
//  part of a debris stream, which is an observed property of that stream and is
//  measured, year after year, by counting meteors. So this table is copied from
//  a published source — the IMO Meteor Shower Calendar's working list of visual
//  showers — and the app is explicit about that everywhere it shows one.
//  See DATA_SOURCES.md for the citation and the licence terms.
//
//  WHAT IS TABULATED AND WHAT IS SOLVED.
//
//  The IMO tabulates each maximum as a **solar longitude** (J2000), not as a
//  calendar date, and that is the right key: the Earth reaches a given solar
//  longitude at nearly the same point in its orbit every year, whereas the
//  calendar date drifts by up to a day with the leap-year cycle. So this file
//  stores the published solar longitude, radiant and rate, and the *date* of
//  each year's maximum is solved from it with the app's own solar ephemeris —
//  exactly the same root find the equinoxes use. That is why the peaks here
//  move correctly from year to year instead of being pinned to a date that is
//  only right one year in four.
//
//  The radiant positions are given for the date of maximum and drift by roughly
//  a degree a day across a shower's activity period. Since the calendar shows
//  the radiant at the maximum, the published position is used as-is; the
//  drift is not modelled, and at the maximum it is by definition zero.
//

import Foundation

/// One entry of the IMO working list.
struct MeteorShower: Identifiable, Hashable, Sendable {
    /// The IMO's three-letter code, which is also a stable identity.
    let id: String
    let name: String
    /// Solar longitude of the maximum, J2000, in degrees. The published key.
    let maximumSolarLongitudeDegrees: Double
    /// Radiant at maximum, J2000.
    let radiant: EquatorialCoordinate
    /// Zenithal hourly rate at maximum: meteors an ideal observer would see
    /// under a magnitude-6.5 sky with the radiant overhead. Real counts are
    /// always lower, which the detail line says.
    let zenithalHourlyRate: Int
    /// Mean geocentric velocity, km/s. What decides whether the meteors are
    /// slow and long or fast and brief.
    let velocityKilometresPerSecond: Double
    /// Approximate activity period, as a plain-language span.
    let activityPeriod: String
    /// The parent body, where one is known.
    let parent: String?
}

enum MeteorShowers {

    /// The IMO working list, majors only.
    ///
    /// Restricted to the showers with a ZHR of about 5 or better, because a
    /// list that includes every minor stream is a list nobody reads. Values are
    /// as published; nothing here is interpolated or averaged.
    static let all: [MeteorShower] = [
        MeteorShower(
            id: "QUA", name: "Quadrantids",
            maximumSolarLongitudeDegrees: 283.15,
            radiant: EquatorialCoordinate(rightAscensionDegrees: 230, declinationDegrees: 49),
            zenithalHourlyRate: 110, velocityKilometresPerSecond: 41,
            activityPeriod: "28 December – 12 January",
            parent: "asteroid 2003 EH1"
        ),
        MeteorShower(
            id: "LYR", name: "Lyrids",
            maximumSolarLongitudeDegrees: 32.32,
            radiant: EquatorialCoordinate(rightAscensionDegrees: 271, declinationDegrees: 34),
            zenithalHourlyRate: 18, velocityKilometresPerSecond: 49,
            activityPeriod: "14 – 30 April",
            parent: "comet C/1861 G1 Thatcher"
        ),
        MeteorShower(
            id: "ETA", name: "eta Aquariids",
            maximumSolarLongitudeDegrees: 45.5,
            radiant: EquatorialCoordinate(rightAscensionDegrees: 338, declinationDegrees: -1),
            zenithalHourlyRate: 50, velocityKilometresPerSecond: 66,
            activityPeriod: "19 April – 28 May",
            parent: "comet 1P/Halley"
        ),
        MeteorShower(
            id: "SDA", name: "Southern delta Aquariids",
            maximumSolarLongitudeDegrees: 127.0,
            radiant: EquatorialCoordinate(rightAscensionDegrees: 340, declinationDegrees: -16),
            zenithalHourlyRate: 25, velocityKilometresPerSecond: 41,
            activityPeriod: "12 July – 23 August",
            parent: "comet 96P/Machholz"
        ),
        MeteorShower(
            id: "CAP", name: "alpha Capricornids",
            maximumSolarLongitudeDegrees: 127.0,
            radiant: EquatorialCoordinate(rightAscensionDegrees: 307, declinationDegrees: -10),
            zenithalHourlyRate: 5, velocityKilometresPerSecond: 23,
            activityPeriod: "3 July – 15 August",
            parent: "comet 169P/NEAT"
        ),
        MeteorShower(
            id: "PER", name: "Perseids",
            maximumSolarLongitudeDegrees: 140.0,
            radiant: EquatorialCoordinate(rightAscensionDegrees: 48, declinationDegrees: 58),
            zenithalHourlyRate: 100, velocityKilometresPerSecond: 59,
            activityPeriod: "17 July – 24 August",
            parent: "comet 109P/Swift-Tuttle"
        ),
        MeteorShower(
            id: "STA", name: "Southern Taurids",
            maximumSolarLongitudeDegrees: 197.0,
            radiant: EquatorialCoordinate(rightAscensionDegrees: 32, declinationDegrees: 9),
            zenithalHourlyRate: 5, velocityKilometresPerSecond: 27,
            activityPeriod: "10 September – 20 November",
            parent: "comet 2P/Encke"
        ),
        MeteorShower(
            id: "ORI", name: "Orionids",
            maximumSolarLongitudeDegrees: 208.0,
            radiant: EquatorialCoordinate(rightAscensionDegrees: 95, declinationDegrees: 16),
            zenithalHourlyRate: 20, velocityKilometresPerSecond: 66,
            activityPeriod: "2 October – 7 November",
            parent: "comet 1P/Halley"
        ),
        MeteorShower(
            id: "NTA", name: "Northern Taurids",
            maximumSolarLongitudeDegrees: 230.0,
            radiant: EquatorialCoordinate(rightAscensionDegrees: 58, declinationDegrees: 22),
            zenithalHourlyRate: 5, velocityKilometresPerSecond: 29,
            activityPeriod: "20 October – 10 December",
            parent: "comet 2P/Encke"
        ),
        MeteorShower(
            id: "LEO", name: "Leonids",
            maximumSolarLongitudeDegrees: 235.27,
            radiant: EquatorialCoordinate(rightAscensionDegrees: 152, declinationDegrees: 22),
            zenithalHourlyRate: 10, velocityKilometresPerSecond: 71,
            activityPeriod: "6 – 30 November",
            parent: "comet 55P/Tempel-Tuttle"
        ),
        MeteorShower(
            id: "GEM", name: "Geminids",
            maximumSolarLongitudeDegrees: 262.2,
            radiant: EquatorialCoordinate(rightAscensionDegrees: 112, declinationDegrees: 33),
            zenithalHourlyRate: 150, velocityKilometresPerSecond: 35,
            activityPeriod: "4 – 20 December",
            parent: "asteroid 3200 Phaethon"
        ),
        MeteorShower(
            id: "URS", name: "Ursids",
            maximumSolarLongitudeDegrees: 270.7,
            radiant: EquatorialCoordinate(rightAscensionDegrees: 217, declinationDegrees: 76),
            zenithalHourlyRate: 10, velocityKilometresPerSecond: 33,
            activityPeriod: "17 – 26 December",
            parent: "comet 8P/Tuttle"
        ),
    ]

    /// Bracketing step for the solar-longitude root find, in days. Same
    /// reasoning as `SeasonEvents`: the Sun advances under a degree a day.
    static let stepDays: Double = 0.5

    /// Every shower maximum falling in `[start, end]`.
    ///
    /// Solved, not looked up: for each tabulated solar longitude, find when the
    /// Sun reaches it. A window spanning a year therefore returns each shower
    /// once, and a window spanning two returns it twice, without this file
    /// knowing anything about years.
    static func events(
        fromJulianDay start: Double, toJulianDay end: Double
    ) -> [AstronomicalEvent] {
        var events: [AstronomicalEvent] = []
        for shower in all {
            let times = EventSolver.crossings(
                of: EclipticLongitude.sunJ2000(julianDay:),
                targetDegrees: shower.maximumSolarLongitudeDegrees,
                from: start, to: end, stepDays: stepDays
            )
            for time in times {
                events.append(event(shower: shower, julianDay: time))
            }
        }
        return events.sorted { $0.julianDay < $1.julianDay }
    }

    static func event(shower: MeteorShower, julianDay: Double) -> AstronomicalEvent {
        // The radiant is a J2000 catalogue place, exactly like a star's, so it
        // is precessed to the equinox of date before it meets the observer's
        // sidereal time — the same treatment `SkyGeometryBuilder` gives every
        // other catalogue position.
        let radiantOfDate = Precession.precess(shower.radiant, julianDay: julianDay)
        var detail = "Up to \(shower.zenithalHourlyRate) an hour under a perfect sky with the radiant overhead; expect fewer. Meteors at \(Int(shower.velocityKilometresPerSecond)) km/s. Active \(shower.activityPeriod)."
        if let parent = shower.parent {
            detail += " Debris from \(parent)."
        }
        return AstronomicalEvent(
            id: "shower-\(shower.id)-\(Int(julianDay))",
            kind: .meteorShower,
            provenance: .tabulated,
            julianDay: julianDay,
            title: shower.name,
            detail: detail,
            // A radiant is not a `CelestialObject`, so there is nothing to
            // select — but there is very much somewhere to look, which is what
            // the target position is for.
            targetObjectID: nil,
            targetEquatorial: radiantOfDate
        )
    }
}
