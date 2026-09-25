//
//  SkyPath.swift
//  Astronomy
//
//  The track a selected object traces across the observer's sky over a chosen
//  span of time, sampled once and drawn through the existing line pass.
//
//  Why this is a *horizontal*-frame path
//  -------------------------------------
//  A path in RA/Dec would be a dot for a star and a short arc for a planet —
//  true, and useless. What a person standing outside sees is the composition of
//  the object's own motion with the Earth's rotation, and that is the horizontal
//  frame. The consequence is that a star still has a path — its diurnal arc,
//  the circle of constant declination it rides from rise to set — which is
//  genuinely the most useful thing the feature can say about a star, so stars
//  are not a degenerate case to be excluded but the simplest case to include.
//
//  Cadence
//  -------
//  Each class gets a base cadence chosen so consecutive samples are of order a
//  degree apart on the sky, which is where a polyline stops looking like a
//  polygon:
//
//    * satellites   ~1 s   — a LEO pass crosses the sky in minutes; at 4 deg/s
//                            anything coarser is a chord, not a track.
//    * Moon         60 s   — 15 deg/hour of diurnal motion plus 0.5 deg/hour of
//                            its own.
//    * Sun/planets 300 s   — diurnal motion dominates entirely.
//    * stars, deep sky, constellations
//                  300 s   — pure diurnal arc; smooth at this step over a night.
//
//  The cadence is then relaxed if the requested span would exceed
//  `maximumSamples`, so a 24-hour path over a satellite cannot produce a
//  hundred thousand points. Satellites additionally have their span clamped —
//  see `satelliteMaximumSpanSeconds`.
//

import Foundation

/// The spans the UI offers.
nonisolated enum SkyPathRange: Hashable {
    case nextHour
    case tonight
    case next24Hours
    /// An explicit window, as Julian Days.
    case custom(startJulianDay: Double, endJulianDay: Double)

    var displayName: String {
        switch self {
        case .nextHour: return "Next hour"
        case .tonight: return "Tonight"
        case .next24Hours: return "24 hours"
        case .custom: return "Custom"
        }
    }
}

/// A time annotation attached to one sample of a path.
nonisolated struct SkyPathLabel {
    /// Index into `SkyPath.samples`.
    let sampleIndex: Int
    /// Local clock time, "14:05".
    let text: String
}

nonisolated struct SkyPathSample {
    let julianDay: Double
    let horizontal: HorizontalCoordinate
}

nonisolated struct SkyPath {
    /// Identity of the object this path belongs to, so the renderer can drop it
    /// the moment the selection changes.
    let objectID: String
    let range: SkyPathRange
    let samples: [SkyPathSample]
    /// Small time labels placed along the track. Formatted here, once, rather
    /// than in the geometry builder: date formatting is expensive and the
    /// builder runs every frame while the path is rebuilt only when the
    /// selection, span or location changes.
    let timeLabels: [SkyPathLabel]
    /// True when the requested span was cut short because the satellite's
    /// element set stops being trustworthy inside it. The UI says so rather
    /// than drawing a confident line through an extrapolation.
    let truncatedForAccuracy: Bool
    /// The span actually sampled, in seconds. May be shorter than requested for
    /// the reason above, or because the object's class caps it.
    let spanSeconds: Double

    var isEmpty: Bool { samples.count < 2 }
    var startJulianDay: Double? { samples.first?.julianDay }
    var endJulianDay: Double? { samples.last?.julianDay }
}

nonisolated enum SkyPathBuilder {

    // MARK: - Cadence

    /// Base sampling interval per object class, in seconds. See the file
    /// comment for how each was chosen.
    static func baseCadenceSeconds(for kind: CelestialObjectKind) -> Double {
        switch kind {
        case .satellite: return 1
        case .moon: return 60
        case .sun, .planet, .dwarfPlanet: return 300
        case .star, .deepSky, .constellation, .planetMoon: return 300
        }
    }

    /// Hard ceiling on the number of samples in one path. 2000 points is one
    /// line-list draw of 4000 vertices appended to a buffer that already
    /// carries a few thousand constellation-line vertices — invisible in the
    /// frame budget, and far more than the eye can resolve along a track.
    static let maximumSamples = 2000

    /// The longest span a satellite path may cover, in seconds.
    ///
    /// One hour is a little over one LEO revolution. Beyond that the drawn line
    /// stops being a *track across your sky* and becomes a repeated ground
    /// path, and — more importantly — SGP4's along-track error grows without
    /// the element set ever being refreshed, so the far end of a long line
    /// carries a confidence the near end does not.
    static let satelliteMaximumSpanSeconds: Double = 3600

    /// Cadence actually used: the class's base, relaxed until the span fits
    /// inside `maximumSamples`.
    static func cadenceSeconds(for kind: CelestialObjectKind, spanSeconds: Double) -> Double {
        let base = baseCadenceSeconds(for: kind)
        let needed = spanSeconds / Double(maximumSamples - 1)
        return max(base, needed)
    }

    /// How many time labels to place along a track. Six is enough to read the
    /// direction and pace of the motion and few enough that they do not become
    /// the drawing.
    static let maximumTimeLabels = 6

    /// Wall-clock formatter for the track annotations. Held statically because
    /// building a `DateFormatter` costs far more than formatting with one.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func timeLabels(samples: [SkyPathSample]) -> [SkyPathLabel] {
        let count = samples.count
        guard count > 1 else { return [] }
        let labels = min(maximumTimeLabels, count)
        guard labels > 1 else { return [] }
        var seen = Set<Int>()
        var result: [SkyPathLabel] = []
        for i in 0..<labels {
            let index = Int((Double(i) * Double(count - 1) / Double(labels - 1)).rounded())
            guard seen.insert(index).inserted else { continue }
            result.append(
                SkyPathLabel(
                    sampleIndex: index,
                    text: timeFormatter.string(
                        from: JulianDate.date(fromJulianDay: samples[index].julianDay)
                    )
                )
            )
        }
        return result
    }

    // MARK: - Span resolution

    /// Turns a range into an explicit `[start, end]` in Julian Days.
    ///
    /// `tonight` is the night's dark window where there is one, and otherwise
    /// sunset to sunrise — the object's path is only interesting while the sky
    /// is dark enough to see it.
    static func span(
        _ range: SkyPathRange, observer: GeographicLocation, julianDay now: Double
    ) -> (start: Double, end: Double) {
        switch range {
        case .nextHour:
            return (now, now + 1.0 / 24.0)
        case .next24Hours:
            return (now, now + 1.0)
        case .custom(let start, let end):
            return (min(start, end), max(start, end))
        case .tonight:
            let night = TonightPlanner.nightWindow(observer: observer, julianDay: now)
            if let dark = night.darkWindow {
                return (dark.lowerBound, dark.upperBound)
            }
            if let sunset = night.sun.eveningJulianDay, let sunrise = night.sun.morningJulianDay {
                return (sunset, sunrise)
            }
            // No sunset at all (polar day): fall back to the whole 24 hours
            // rather than returning an empty span.
            return (night.anchorJulianDay, night.anchorJulianDay + 1)
        }
    }

    // MARK: - Building

    /// A path for anything whose position is a function of time in the
    /// equatorial frame — Sun, Moon, planets, and (with a constant provider)
    /// stars and deep-sky objects.
    static func build(
        objectID: String,
        kind: CelestialObjectKind,
        range: SkyPathRange,
        equatorialAt: (Double) -> EquatorialCoordinate,
        observer: GeographicLocation,
        julianDay now: Double
    ) -> SkyPath {
        let (start, end) = span(range, observer: observer, julianDay: now)
        let spanSeconds = max(0, (end - start) * 86_400.0)
        let cadence = cadenceSeconds(for: kind, spanSeconds: spanSeconds)
        let steps = max(1, Int((spanSeconds / cadence).rounded(.down)))

        var samples: [SkyPathSample] = []
        samples.reserveCapacity(steps + 1)
        for i in 0...steps {
            let jd = start + Double(i) * cadence / 86_400.0
            samples.append(
                SkyPathSample(
                    julianDay: jd,
                    horizontal: CoordinateTransformService.horizontal(
                        from: equatorialAt(jd), observer: observer, julianDay: jd
                    )
                )
            )
        }
        // The requested end is an endpoint the user asked for, so it is always
        // present even when the cadence does not divide the span evenly.
        if let last = samples.last, last.julianDay < end - 1e-9 {
            samples.append(
                SkyPathSample(
                    julianDay: end,
                    horizontal: CoordinateTransformService.horizontal(
                        from: equatorialAt(end), observer: observer, julianDay: end
                    )
                )
            )
        }

        return SkyPath(
            objectID: objectID,
            range: range,
            samples: samples,
            timeLabels: timeLabels(samples: samples),
            truncatedForAccuracy: false,
            spanSeconds: spanSeconds
        )
    }

    /// A path for a fixed catalogue position: the diurnal arc.
    static func build(
        objectID: String,
        kind: CelestialObjectKind,
        range: SkyPathRange,
        fixedEquatorialOfDate: EquatorialCoordinate,
        observer: GeographicLocation,
        julianDay now: Double
    ) -> SkyPath {
        build(
            objectID: objectID,
            kind: kind,
            range: range,
            equatorialAt: { _ in fixedEquatorialOfDate },
            observer: observer,
            julianDay: now
        )
    }

    /// The instants a satellite path should be sampled at, with both satellite
    /// gates already applied.
    ///
    /// Split out from the path assembly because the propagation itself lives on
    /// `SatelliteTracker`'s actor: the caller asks for the times here, hands
    /// them to the tracker in one batch, and assembles the result with
    /// `satellitePath`. Splitting it this way is also what makes the gates
    /// directly testable without an SGP4 propagator.
    ///
    /// Two gates apply on top of the ordinary sampling, and both are the ones
    /// the satellite *markers* already obey rather than new policy:
    ///
    ///  * the span is clamped to `satelliteMaximumSpanSeconds`;
    ///  * every sample time must pass `SatelliteAccuracy.isDrawable` against
    ///    this element set's epoch. The first time that fails ends the track,
    ///    so a path extending past the validity window is never drawn as
    ///    though it were reliable — and stopping (rather than skipping and
    ///    resuming) avoids a gap that would read as two separate passes.
    static func satelliteSampleTimes(
        range: SkyPathRange,
        observer: GeographicLocation,
        julianDay now: Double,
        epochJulianDay: Double,
        nowJulianDay: Double
    ) -> (times: [Double], truncatedForAccuracy: Bool) {
        let (start, rawEnd) = span(range, observer: observer, julianDay: now)
        let requestedSeconds = max(0, (rawEnd - start) * 86_400.0)
        let clampedSeconds = min(requestedSeconds, satelliteMaximumSpanSeconds)
        var truncated = clampedSeconds < requestedSeconds - 1e-6

        let cadence = cadenceSeconds(for: .satellite, spanSeconds: clampedSeconds)
        let steps = max(1, Int((clampedSeconds / cadence).rounded(.down)))

        var times: [Double] = []
        times.reserveCapacity(steps + 1)
        for i in 0...steps {
            let jd = start + Double(i) * cadence / 86_400.0
            guard SatelliteAccuracy.isDrawable(
                julianDay: jd, nowJulianDay: nowJulianDay, epochJulianDay: epochJulianDay
            ) else {
                truncated = true
                break
            }
            times.append(jd)
        }
        return (times, truncated)
    }

    /// Assembles the path from the times and whatever the propagator returned
    /// for them. A `nil` look angle ends the track.
    static func satellitePath(
        objectID: String,
        range: SkyPathRange,
        times: [Double],
        horizontals: [HorizontalCoordinate?],
        truncatedForAccuracy: Bool
    ) -> SkyPath {
        var truncated = truncatedForAccuracy
        var samples: [SkyPathSample] = []
        samples.reserveCapacity(min(times.count, horizontals.count))
        for (index, jd) in times.enumerated() {
            guard index < horizontals.count, let horizontal = horizontals[index] else {
                truncated = true
                break
            }
            samples.append(SkyPathSample(julianDay: jd, horizontal: horizontal))
        }
        return SkyPath(
            objectID: objectID,
            range: range,
            samples: samples,
            timeLabels: timeLabels(samples: samples),
            truncatedForAccuracy: truncated,
            spanSeconds: samples.count > 1
                ? (samples[samples.count - 1].julianDay - samples[0].julianDay) * 86_400.0
                : 0
        )
    }

    /// Convenience form for callers that can propagate synchronously.
    static func buildSatellite(
        objectID: String,
        range: SkyPathRange,
        epochJulianDay: Double,
        nowJulianDay: Double,
        observer: GeographicLocation,
        julianDay now: Double,
        positionAt: (Double) -> HorizontalCoordinate?
    ) -> SkyPath {
        let (times, truncated) = satelliteSampleTimes(
            range: range, observer: observer, julianDay: now,
            epochJulianDay: epochJulianDay, nowJulianDay: nowJulianDay
        )
        return satellitePath(
            objectID: objectID, range: range, times: times,
            horizontals: times.map(positionAt), truncatedForAccuracy: truncated
        )
    }
}
