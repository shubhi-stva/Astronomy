//
//  TonightReport.swift
//  Astronomy
//
//  "What is actually worth looking at tonight, from here?" — assembled from
//  `RiseSetCalculator` (when things are up) and `VisibilityRating` (how well
//  they can be seen), with no new astronomy of its own.
//
//  Everything here is pure computation over value types: no SwiftUI, no Metal,
//  no actor isolation, so it is directly unit-testable and can be computed off
//  the main thread.
//

import Foundation

// MARK: - The night itself

/// Sunset and the three twilight boundaries, evening and morning.
///
/// Every field is optional because at sufficiently high latitude the crossing
/// genuinely does not happen — a Tromso June has no sunset at all, and a
/// Reykjavik June has sunset but never reaches -18 degrees. Reporting `nil`
/// with a `Circumstance` alongside is the only honest answer; inventing a time
/// would be worse than saying nothing.
struct TwilightBoundary {
    /// Evening crossing (Sun descending through the threshold).
    let eveningJulianDay: Double?
    /// Morning crossing (Sun ascending back through it).
    let morningJulianDay: Double?
    let circumstance: RiseSetCalculator.Circumstance

    /// True when the Sun spends part of the window below the threshold.
    var occurs: Bool { eveningJulianDay != nil || circumstance == .neverUp }
}

struct NightWindow {
    /// Local solar noon that anchors this night. The whole window is the day
    /// running noon-to-noon from here, which is the only anchor for which
    /// "sunset then sunrise" is unambiguously one night rather than two halves
    /// of two different ones.
    let anchorJulianDay: Double

    /// Sun crossing -0.8333 deg (upper limb, refracted): sunset and sunrise.
    let sun: TwilightBoundary
    let civil: TwilightBoundary
    let nautical: TwilightBoundary
    let astronomical: TwilightBoundary

    /// The interval of true astronomical darkness, if there is one.
    var darkWindow: ClosedRange<Double>? {
        guard let start = astronomical.eveningJulianDay,
              let end = astronomical.morningJulianDay,
              end > start else { return nil }
        return start...end
    }

    var astronomicalNightOccurs: Bool { darkWindow != nil }

    /// Hours of true darkness, 0 if there is none.
    var darkHours: Double {
        guard let window = darkWindow else { return 0 }
        return (window.upperBound - window.lowerBound) * 24.0
    }
}

// MARK: - The Moon

struct MoonTonight {
    let illuminatedFraction: Double
    /// Waxing crescent, full, etc. — derived from the illuminated fraction and
    /// the sign of the elongation, never from a synodic-age lookup.
    let phaseName: String
    let riseJulianDay: Double?
    let setJulianDay: Double?
    let transitJulianDay: Double
    let transitAltitudeDegrees: Double
    let circumstance: RiseSetCalculator.Circumstance
    /// Fraction of the night's dark window during which the Moon is up. This is
    /// the number the visibility model actually consumes.
    let upFractionOfDarkWindow: Double

    /// Phase naming, from the illuminated fraction plus whether the Moon is
    /// waxing. The boundaries are the conventional ones: 1% for new, 99% for
    /// full, and 45-55% for the quarters.
    static func phaseName(illuminatedFraction k: Double, isWaxing: Bool) -> String {
        switch k {
        case ..<0.01: return "New Moon"
        case ..<0.45: return isWaxing ? "Waxing Crescent" : "Waning Crescent"
        case ..<0.55: return isWaxing ? "First Quarter" : "Last Quarter"
        case ..<0.99: return isWaxing ? "Waxing Gibbous" : "Waning Gibbous"
        default: return "Full Moon"
        }
    }
}

// MARK: - A rated target

/// One thing worth (or not worth) pointing at tonight, with the whole
/// derivation attached.
struct TonightTarget: Identifiable {
    let id: String
    let name: String
    let kind: CelestialObjectKind
    /// Catalogue designation where the display name is a common one.
    let designation: String?
    let magnitude: Double
    let riseJulianDay: Double?
    let setJulianDay: Double?
    let transitJulianDay: Double
    let transitAltitudeDegrees: Double
    let circumstance: RiseSetCalculator.Circumstance
    /// Highest altitude reached *during astronomical darkness*, which is the
    /// altitude the rating uses — not the transit altitude, which may happen
    /// in daylight.
    let peakAltitudeInDarknessDegrees: Double
    let visibility: VisibilityAssessment

    var typeDescription: String?
}

// MARK: - The report

struct TonightReport {
    let observer: GeographicLocation
    let night: NightWindow
    let moon: MoonTonight
    /// Planets that get above the useful altitude at some point tonight,
    /// brightest first.
    let planets: [TonightTarget]
    /// The best deep-sky targets, best band first then highest first.
    let deepSky: [TonightTarget]
}

// MARK: - Construction

enum TonightPlanner {

    /// How many deep-sky targets to surface. A list this size fits on screen
    /// without scrolling and is about as many objects as one session covers.
    static let deepSkyTargetLimit = 12

    /// Deep-sky entries fainter than this are not considered: past magnitude 12
    /// the assumed 80 mm aperture (see `VisibilityRating`) cannot reach them
    /// under any sky, so rating them would only produce a wall of "Not visible".
    static let deepSkyMagnitudeCutoff: Double = 12.0

    /// Sampling step, in days, for the "how long is it up in the dark" pass.
    /// Five minutes: fine enough that the accumulated hours are good to a few
    /// minutes, coarse enough that 900 catalogue entries cost one pass each.
    static let darkWindowStepDays: Double = 5.0 / 1440.0

    // MARK: Night window

    /// The local solar noon that anchors the night containing `julianDay`.
    ///
    /// Anchoring on the Sun's transit rather than on midnight is what makes the
    /// window unambiguous: between noon and the following noon there is exactly
    /// one sunset and one sunrise, in that order, so "tonight" needs no special
    /// cases for a user scrubbing to 2am. The consequence, stated plainly, is
    /// that before local noon the report describes the night now ending rather
    /// than the one about to begin — which is the right answer for someone
    /// still outside at 2am, and the price of having no ambiguous instants.
    static func anchorJulianDay(observer: GeographicLocation, julianDay: Double) -> Double {
        let nearest = solarTransit(observer: observer, near: julianDay)
        if nearest <= julianDay { return nearest }
        // Before this transit, so the night in progress began at the previous
        // one — found by the same solver rather than by subtracting a day, since
        // successive solar transits are not exactly 24 hours apart.
        return solarTransit(observer: observer, near: julianDay - 1.0)
    }

    /// The solar transit nearest `julianDay`, i.e. the instant the Sun's hour
    /// angle is zero.
    ///
    /// A direct Newton iteration on the hour angle rather than a search for the
    /// altitude maximum: hour angle has a single zero per day and a known,
    /// almost constant rate (360.985647 deg/day, the sidereal rotation rate),
    /// which makes this both unambiguous — the altitude maximum in a 24-hour
    /// window is not, since such a window can contain two transits — and exact
    /// to the millisecond in three iterations.
    static func solarTransit(observer: GeographicLocation, near julianDay: Double) -> Double {
        var t = julianDay
        for _ in 0..<5 {
            let lst = CoordinateTransformService.localSiderealTimeDegrees(
                julianDay: t, longitudeDegrees: observer.longitudeDegrees
            )
            let ra = SunPosition.equatorialCoordinate(julianDay: t).rightAscensionDegrees
            var hourAngle = Angle.normalizeDegrees(lst - ra)
            if hourAngle > 180 { hourAngle -= 360 }
            let correction = hourAngle / 360.985647
            t -= correction
            if abs(correction) < 1e-9 { break }
        }
        return t
    }

    private static func boundary(
        standardAltitudeDegrees: Double, observer: GeographicLocation, anchor: Double
    ) -> TwilightBoundary {
        let result = RiseSetCalculator.sunEvents(
            standardAltitudeDegrees: standardAltitudeDegrees,
            observer: observer,
            startJulianDay: anchor,
            durationDays: 1.0
        )
        return TwilightBoundary(
            eveningJulianDay: result.setJulianDay,
            morningJulianDay: result.riseJulianDay,
            circumstance: result.circumstance
        )
    }

    static func nightWindow(observer: GeographicLocation, julianDay: Double) -> NightWindow {
        let anchor = anchorJulianDay(observer: observer, julianDay: julianDay)
        return NightWindow(
            anchorJulianDay: anchor,
            sun: boundary(
                standardAltitudeDegrees: RiseSetCalculator.StandardAltitude.sun,
                observer: observer, anchor: anchor
            ),
            civil: boundary(
                standardAltitudeDegrees: RiseSetCalculator.StandardAltitude.civilTwilight,
                observer: observer, anchor: anchor
            ),
            nautical: boundary(
                standardAltitudeDegrees: RiseSetCalculator.StandardAltitude.nauticalTwilight,
                observer: observer, anchor: anchor
            ),
            astronomical: boundary(
                standardAltitudeDegrees: RiseSetCalculator.StandardAltitude.astronomicalTwilight,
                observer: observer, anchor: anchor
            )
        )
    }

    // MARK: Moon

    static func moonTonight(observer: GeographicLocation, night: NightWindow) -> MoonTonight {
        let events = RiseSetCalculator.moonEvents(
            observer: observer, startJulianDay: night.anchorJulianDay, durationDays: 1.0
        )
        // Phase is evaluated at the middle of the dark window when there is
        // one, otherwise at local midnight — the instant the user is being told
        // about, not an arbitrary epoch.
        let reference = night.darkWindow.map { ($0.lowerBound + $0.upperBound) * 0.5 }
            ?? (night.anchorJulianDay + 0.5)
        let sun = SunPosition.equatorialCoordinate(julianDay: reference)
        let moon = MoonPosition.equatorialCoordinate(julianDay: reference)
        let k = MoonPhase.illuminatedFraction(sun: sun, moon: moon)

        var upFraction = 0.0
        if let window = night.darkWindow {
            var samples = 0
            var up = 0
            var t = window.lowerBound
            while t <= window.upperBound {
                let altitude = CoordinateTransformService.horizontal(
                    from: MoonPosition.equatorialCoordinate(julianDay: t),
                    observer: observer, julianDay: t
                ).altitudeDegrees
                samples += 1
                if altitude > 0 { up += 1 }
                t += darkWindowStepDays
            }
            upFraction = samples > 0 ? Double(up) / Double(samples) : 0
        }

        return MoonTonight(
            illuminatedFraction: k,
            phaseName: MoonTonight.phaseName(
                illuminatedFraction: k,
                isWaxing: MoonPhase.isWaxing(sun: sun, moon: moon)
            ),
            riseJulianDay: events.riseJulianDay,
            setJulianDay: events.setJulianDay,
            transitJulianDay: events.transitJulianDay,
            transitAltitudeDegrees: events.transitAltitudeDegrees,
            circumstance: events.circumstance,
            upFractionOfDarkWindow: upFraction
        )
    }

    // MARK: Targets

    /// Peak altitude and hours above the useful altitude, both restricted to
    /// astronomical darkness. One pass, because both come from the same sample
    /// grid.
    private static func darknessStatistics(
        equatorialAt: (Double) -> EquatorialCoordinate,
        observer: GeographicLocation,
        darkWindow: ClosedRange<Double>?
    ) -> (peakAltitudeDegrees: Double, hours: Double, peakJulianDay: Double) {
        guard let window = darkWindow else { return (-90, 0, 0) }
        var peak = -90.0
        var peakTime = window.lowerBound
        var usefulSamples = 0
        var samples = 0
        var t = window.lowerBound
        while t <= window.upperBound {
            let altitude = CoordinateTransformService.horizontal(
                from: equatorialAt(t), observer: observer, julianDay: t
            ).altitudeDegrees
            if altitude > peak {
                peak = altitude
                peakTime = t
            }
            if altitude >= VisibilityRating.usefulAltitudeDegrees { usefulSamples += 1 }
            samples += 1
            t += darkWindowStepDays
        }
        let totalHours = (window.upperBound - window.lowerBound) * 24.0
        let hours = samples > 0 ? totalHours * Double(usefulSamples) / Double(samples) : 0
        return (peak, hours, peakTime)
    }

    private static func target(
        id: String,
        name: String,
        kind: CelestialObjectKind,
        designation: String?,
        typeDescription: String?,
        magnitude: Double,
        majorAxisArcmin: Double?,
        minorAxisArcmin: Double?,
        equatorialAt: (Double) -> EquatorialCoordinate,
        standardAltitudeDegrees: Double,
        observer: GeographicLocation,
        night: NightWindow,
        moon: MoonTonight
    ) -> TonightTarget {
        let events = RiseSetCalculator.events(
            equatorialAt: equatorialAt,
            standardAltitudeDegrees: standardAltitudeDegrees,
            observer: observer,
            startJulianDay: night.anchorJulianDay,
            durationDays: 1.0
        )
        let stats = darknessStatistics(
            equatorialAt: equatorialAt, observer: observer, darkWindow: night.darkWindow
        )
        // Separation is taken at the moment the object is best placed, which is
        // when the observer would actually be looking at it.
        let separationReference = night.darkWindow == nil ? events.transitJulianDay : stats.peakJulianDay
        let separation = VisibilityRating.angularSeparationDegrees(
            equatorialAt(separationReference),
            MoonPosition.equatorialCoordinate(julianDay: separationReference)
        )
        let visibility = VisibilityRating.assess(
            magnitude: magnitude,
            majorAxisArcmin: majorAxisArcmin,
            minorAxisArcmin: minorAxisArcmin,
            peakAltitudeDegrees: stats.peakAltitudeDegrees,
            hoursInDarkness: stats.hours,
            moonIlluminatedFraction: moon.illuminatedFraction,
            moonSeparationDegrees: separation,
            moonUpFractionOfDarkWindow: moon.upFractionOfDarkWindow
        )
        return TonightTarget(
            id: id,
            name: name,
            kind: kind,
            designation: designation,
            magnitude: magnitude,
            riseJulianDay: events.riseJulianDay,
            setJulianDay: events.setJulianDay,
            transitJulianDay: events.transitJulianDay,
            transitAltitudeDegrees: events.transitAltitudeDegrees,
            circumstance: events.circumstance,
            peakAltitudeInDarknessDegrees: stats.peakAltitudeDegrees,
            visibility: visibility,
            typeDescription: typeDescription
        )
    }

    /// The planets that get anywhere tonight. Pluto is excluded: at magnitude
    /// ~14 it fails the brightness constraint from any site, and listing it
    /// every night as "Not visible" is noise.
    static func planetsTonight(
        observer: GeographicLocation, night: NightWindow, moon: MoonTonight
    ) -> [TonightTarget] {
        Planet.allCases
            .filter { !$0.isDwarfPlanet }
            .map { planet in
                target(
                    id: planet.rawValue,
                    name: planet.displayName,
                    kind: .planet,
                    designation: nil,
                    typeDescription: "Planet",
                    magnitude: EphemerisService.approximateMagnitudeForPlanning(planet),
                    majorAxisArcmin: nil,
                    minorAxisArcmin: nil,
                    equatorialAt: { PlanetPosition.equatorialCoordinate(planet: planet, julianDay: $0) },
                    standardAltitudeDegrees: RiseSetCalculator.StandardAltitude.point,
                    observer: observer,
                    night: night,
                    moon: moon
                )
            }
            .filter { $0.visibility.band > .notVisible || $0.transitAltitudeDegrees > 0 }
            .sorted { $0.magnitude < $1.magnitude }
    }

    static func deepSkyTonight(
        catalogue: [DeepSkyObject],
        observer: GeographicLocation,
        night: NightWindow,
        moon: MoonTonight,
        limit: Int = deepSkyTargetLimit
    ) -> [TonightTarget] {
        catalogue
            .filter { $0.type.isRenderable && $0.magnitude <= deepSkyMagnitudeCutoff }
            .map { object -> TonightTarget in
                let ofDate = Precession.precess(
                    object.equatorial, julianDay: night.anchorJulianDay
                )
                return target(
                    id: object.id,
                    name: object.displayName,
                    kind: .deepSky,
                    designation: object.catalogName == object.displayName ? nil : object.catalogName,
                    typeDescription: object.type.displayName,
                    magnitude: object.magnitude,
                    majorAxisArcmin: object.majorAxisArcmin,
                    minorAxisArcmin: object.minorAxisArcmin,
                    equatorialAt: { _ in ofDate },
                    standardAltitudeDegrees: RiseSetCalculator.StandardAltitude.point,
                    observer: observer,
                    night: night,
                    moon: moon
                )
            }
            .filter { $0.visibility.band > .notVisible }
            // Best band first; within a band the better-placed object wins,
            // because at equal rating altitude is what actually decides how the
            // view looks.
            .sorted {
                if $0.visibility.band != $1.visibility.band {
                    return $0.visibility.band > $1.visibility.band
                }
                if $0.visibility.detectionMarginMagnitudes != $1.visibility.detectionMarginMagnitudes {
                    return $0.visibility.detectionMarginMagnitudes > $1.visibility.detectionMarginMagnitudes
                }
                return $0.peakAltitudeInDarknessDegrees > $1.peakAltitudeInDarknessDegrees
            }
            .prefix(limit)
            .map { $0 }
    }

    /// The whole report. Costs roughly a second of arithmetic over the full
    /// deep-sky catalogue, so callers compute it off the main thread and only
    /// when the location, the night or the panel's visibility changes.
    static func report(
        observer: GeographicLocation,
        julianDay: Double,
        deepSkyCatalogue: [DeepSkyObject],
        deepSkyLimit: Int = deepSkyTargetLimit
    ) -> TonightReport {
        let night = nightWindow(observer: observer, julianDay: julianDay)
        let moon = moonTonight(observer: observer, night: night)
        return TonightReport(
            observer: observer,
            night: night,
            moon: moon,
            planets: planetsTonight(observer: observer, night: night, moon: moon),
            deepSky: deepSkyTonight(
                catalogue: deepSkyCatalogue, observer: observer,
                night: night, moon: moon, limit: deepSkyLimit
            )
        )
    }
}
