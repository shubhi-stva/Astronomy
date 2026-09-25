//
//  InfoPanelView.swift
//  Astronomy
//
//  Minimal floating panel shown when a star/planet/Sun/Moon is selected:
//  name, magnitude, RA/Dec. Intentionally minimal for the Phase 1 MVP.
//

import SwiftUI

struct InfoPanelView: View {
    let object: CelestialObject
    var onDismiss: () -> Void

    /// Where the object is right now and what its day looks like. Optional so
    /// the panel still renders (and previews) without a view model behind it.
    var facts: ObjectFacts?
    /// Formats instants in the observer's own time zone.
    var timeZone: TimeZone = .current
    /// Constellation names by IAU abbreviation, so "Ori" can be printed as
    /// "Orion". Empty is fine — the abbreviation is shown alone.
    var constellationNames: [String: String] = [:]

    /// Sky-path controls. Optional so the panel remains usable (and previewable)
    /// on its own; when a handler is supplied the "Show path" row appears.
    var pathRange: SkyPathRange?
    var onSelectPathRange: ((SkyPathRange) -> Void)?
    /// Set when the drawn path had to be cut short — a satellite path running
    /// past the element set's validity window. Shown rather than silently
    /// truncating.
    var pathTruncated: Bool = false

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: SkyMetrics.rowSpacing) {
                HStack {
                    Text(object.name)
                        .font(SkyType.panelTitle)
                        .foregroundStyle(SkyPalette.chromeText)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(SkyPalette.chromeSecondaryText)
                    }
                    .buttonStyle(.plain)
                }

                // The kind is a category, not a sentence, so it is set as a
                // tracked section label in caps rather than as caption text.
                // At 9pt with 0.7 of tracking it reads as a tag under the name
                // instead of as a second, competing line of prose.
                Text(kindLabel.uppercased())
                    .font(SkyType.sectionLabel)
                    .tracking(SkyType.sectionLabelSpec.tracking)
                    .foregroundStyle(SkyPalette.accentBlue.opacity(0.9))

                Divider().overlay(SkyPalette.panelStroke)

                if let designation = object.catalogDesignation, designation != object.name {
                    infoRow("Catalogue", designation)
                }
                if let satellite = object.satelliteDetails {
                    satelliteRows(satellite)
                } else if object.kind != .constellation {
                    // A constellation is a region of sky, not a light source;
                    // it has no magnitude and printing 0.00 would invent one.
                    infoRow("Magnitude", String(format: "%.2f", object.magnitude))
                }
                if let major = object.majorAxisArcmin {
                    infoRow("Size", angularSizeString(major: major, minor: object.minorAxisArcmin))
                }
                solarSystemRows

                infoRow("Right Ascension", raString)
                infoRow("Declination", decString)

                if let facts {
                    positionRows(facts)
                }

                if let onSelectPathRange {
                    pathControls(onSelectPathRange)
                }
            }
        }
        .frame(width: 280)
    }

    /// Where the object is in *this* observer's sky, and what it does today.
    ///
    /// This is the half of the panel that makes the app a guide rather than a
    /// chart: altitude and azimuth say where to point, the constellation says
    /// what you are looking at, and rise/transit/set say whether it is worth
    /// waiting. A satellite gets only the live half — a pass is not a daily
    /// rise, and the passes panel predicts those properly.
    @ViewBuilder
    private func positionRows(_ facts: ObjectFacts) -> some View {
        let live = facts.live
        infoRow("Altitude", altitudeString(live))
        infoRow("Azimuth", String(format: "%.1f° %@", live.horizontal.azimuthDegrees,
                                  Self.compassPoint(live.horizontal.azimuthDegrees)))

        if let constellation = facts.daily?.constellationAbbreviation, object.kind != .constellation {
            infoRow("In", constellationNames[constellation] ?? constellation)
        }

        if let daily = facts.daily, object.kind != .satellite {
            Divider().overlay(SkyPalette.panelStroke)
            switch daily.circumstance {
            case .alwaysUp:
                Text("Circumpolar from here — it never sets.")
                    .font(SkyType.footnote)
                    .foregroundStyle(SkyPalette.chromeSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            case .neverUp:
                Text("Never rises from this latitude today.")
                    .font(SkyType.footnote)
                    .foregroundStyle(SkyPalette.chromeSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                if let rise = daily.riseJulianDay {
                    infoRow("Rises", clockString(rise))
                }
            }
            if let transit = daily.transitJulianDay, let altitude = daily.transitAltitudeDegrees {
                infoRow("Highest", String(format: "%@ · %.0f°", clockString(transit), altitude))
            }
            if daily.circumstance == .risesAndSets, let set = daily.setJulianDay {
                infoRow("Sets", clockString(set))
            }
        }
    }

    /// Distance, apparent size, phase and elongation — the facts that make a
    /// planet a place rather than a dot.
    @ViewBuilder
    private var solarSystemRows: some View {
        if let distance = object.distanceKilometres, object.kind != .satellite {
            infoRow("Distance", ObjectFacts.distanceDescription(kilometres: distance))
            let diameter = StarAppearance.angularDiameterDegrees(
                objectID: object.id, distanceKilometres: distance
            )
            if diameter > 0 {
                infoRow("Apparent size", ObjectFacts.angularDiameterDescription(degrees: diameter))
            }
        }
        if let illuminated = object.illuminatedFraction, object.kind != .sun {
            infoRow("Illuminated", String(format: "%.0f%%", illuminated * 100))
        }
        if let elongation = object.elongationDegrees, object.kind == .planet || object.kind == .dwarfPlanet {
            infoRow("From the Sun", String(format: "%.0f°", elongation))
        }
    }

    private func altitudeString(_ live: ObjectFacts.Live) -> String {
        let geometric = String(format: "%+.1f°", live.horizontal.altitudeDegrees)
        // Refraction is only worth spelling out where it is worth more than a
        // tenth of a degree, which is to say near the horizon — exactly where
        // it changes whether the object is up at all.
        let lift = live.apparentAltitudeDegrees - live.horizontal.altitudeDegrees
        guard lift >= 0.05 else { return geometric }
        return String(format: "%@ (%+.1f° refracted)", geometric, live.apparentAltitudeDegrees)
    }

    private func clockString(_ julianDay: Double) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: JulianDate.date(fromJulianDay: julianDay))
    }

    /// IAU abbreviation -> constellation name, for the "In" row. Taken from
    /// the same normative table search uses, so the two can never disagree.
    static let constellationNames: [String: String] = ConstellationDesignations.byAbbreviation
        .reduce(into: [:]) { $0[$1.key] = $1.value.name }

    /// Sixteen-point compass bearing for an azimuth.
    static func compassPoint(_ azimuthDegrees: Double) -> String {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                      "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let index = Int((Angle.normalizeDegrees(azimuthDegrees) / 22.5).rounded()) % points.count
        return points[index]
    }

    /// "Show path" — one segmented row of spans, and a caveat line when the
    /// drawn track had to stop early.
    ///
    /// A star's path is offered too: it is the diurnal arc, which is exactly
    /// the useful thing to know about a star (where it will be at 2am), so
    /// there is no kind of object this row is hidden for.
    @ViewBuilder
    private func pathControls(_ select: @escaping (SkyPathRange) -> Void) -> some View {
        Divider().overlay(SkyPalette.panelStroke)

        Text("Show path".uppercased())
            .font(SkyType.sectionLabel)
            .tracking(SkyType.sectionLabelSpec.tracking)
            .foregroundStyle(SkyPalette.accentBlue.opacity(0.9))

        HStack(spacing: SkyMetrics.paddingTight) {
            ForEach(Self.offeredRanges, id: \.self) { range in
                Button {
                    select(range)
                } label: {
                    Text(range.displayName)
                        .font(SkyType.control)
                        .foregroundStyle(
                            pathRange == range ? SkyPalette.accentBlue : SkyPalette.chromeSecondaryText
                        )
                        .padding(.horizontal, SkyMetrics.paddingSnug)
                        .padding(.vertical, SkyMetrics.paddingTight)
                        .background(
                            RoundedRectangle(cornerRadius: SkyMetrics.radiusInner, style: .continuous)
                                .fill(Color.white.opacity(pathRange == range ? 0.10 : 0.04))
                        )
                }
                .buttonStyle(.plain)
            }
        }

        if pathTruncated {
            Text(object.kind == .satellite
                 ? "The track stops where this element set stops being reliable."
                 : "The track was shortened to keep it accurate.")
                .font(SkyType.footnote)
                .foregroundStyle(SkyPalette.warningAmber)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The three fixed spans. A custom range is expressible in the model
    /// (`SkyPathRange.custom`) and reachable via the time machine plus
    /// "24 hours"; it is not given a date-picker here because a second picker
    /// competing with the time bar is exactly the chrome this app avoids.
    private static let offeredRanges: [SkyPathRange] = [.nextHour, .tonight, .next24Hours]

    private var kindLabel: String {
        switch object.kind {
        case .star: return "Star"
        case .sun: return "Sun"
        case .moon: return "Moon"
        case .planet: return "Planet"
        case .dwarfPlanet: return "Dwarf Planet"
        case .constellation: return "Constellation"
        case .planetMoon: return "Moon of Jupiter"
        case .deepSky: return object.deepSkyType?.displayName ?? "Deep-Sky Object"
        case .satellite: return object.satelliteDetails?.regime.displayName ?? "Satellite"
        }
    }

    /// The satellite-specific rows.
    ///
    /// Apparent magnitude is deliberately absent: the element-set catalogue
    /// carries no photometry, and a satellite's brightness depends on its
    /// attitude and phase angle in ways two lines of orbital elements cannot
    /// express. Showing a made-up number would be worse than showing none.
    ///
    /// The element-set age is here because it is the honest accuracy caveat.
    /// A LEO element set drifts by kilometres of along-track error per day, so
    /// the age is the single number that tells you how much to trust the
    /// position above it.
    @ViewBuilder
    private func satelliteRows(_ satellite: SatelliteDetails) -> some View {
        infoRow("NORAD ID", "\(satellite.catalogNumber)")
        if !satellite.internationalDesignator.isEmpty {
            infoRow("Int'l designator", satellite.internationalDesignator)
        }
        infoRow("Orbit", satellite.regime.shortName)
        infoRow("Altitude", String(format: "%.0f km", satellite.altitudeAboveGroundKm))
        infoRow("Range", String(format: "%.0f km", satellite.rangeKilometres))
        infoRow("Altitude (alt)", String(format: "%+.2f°", satellite.horizontal.altitudeDegrees))
        infoRow("Azimuth", String(format: "%.2f°", satellite.horizontal.azimuthDegrees))
        infoRow("Sunlight", illuminationText(satellite.illumination))
        infoRow("Element set", elementAgeText(satellite.elementSetAgeDays))
        // What that age means for the numbers directly above it. A position
        // from week-old elements is still worth drawing; presenting it with the
        // same confidence as an hour-old one would not be.
        if let caveat = SatelliteAccuracy.staleness(ageDays: satellite.elementSetAgeDays).caveat {
            Text(caveat)
                .font(SkyType.footnoteNumeric)
                .foregroundStyle(
                    SatelliteAccuracy.staleness(ageDays: satellite.elementSetAgeDays) == .unreliable
                        ? SkyPalette.warningAmber
                        : SkyPalette.chromeSecondaryText
                )
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func illuminationText(_ illumination: TopocentricTransform.Illumination) -> String {
        switch illumination {
        case .sunlit: return "Sunlit"
        case .penumbra: return "Entering shadow"
        case .umbra: return "In Earth's shadow"
        }
    }

    private func elementAgeText(_ days: Double) -> String {
        let age: String
        if days < 0 {
            age = String(format: "%.1f days ahead", -days)
        } else if days < 1 {
            age = String(format: "%.0f hours old", days * 24)
        } else {
            age = String(format: "%.1f days old", days)
        }
        guard let qualifier = SatelliteAccuracy.staleness(ageDays: days).shortLabel else { return age }
        return "\(age) — \(qualifier)"
    }

    /// Angular extent in arcminutes, "major x minor" when both are known.
    private func angularSizeString(major: Double, minor: Double?) -> String {
        guard let minor, minor > 0, minor < major else {
            return String(format: "%.1f'", major)
        }
        return String(format: "%.1f' x %.1f'", major, minor)
    }

    private var raString: String {
        let hours = object.equatorial.rightAscensionHours
        let h = Int(hours)
        let minutesFull = (hours - Double(h)) * 60
        let m = Int(minutesFull)
        let s = (minutesFull - Double(m)) * 60
        return String(format: "%02dh %02dm %04.1fs", h, m, s)
    }

    private var decString: String {
        let dec = object.equatorial.declinationDegrees
        let sign = dec >= 0 ? "+" : "-"
        let absDec = abs(dec)
        let d = Int(absDec)
        let minutesFull = (absDec - Double(d)) * 60
        let m = Int(minutesFull)
        let s = (minutesFull - Double(m)) * 60
        return String(format: "%@%02d° %02d' %04.1f\"", sign, d, m, s)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: SkyMetrics.paddingSnug) {
            Text(label)
                .font(SkyType.caption)
                .foregroundStyle(SkyPalette.chromeSecondaryText)
            Spacer(minLength: SkyMetrics.paddingSnug)
            // Every value in this panel is or contains a number — RA, Dec,
            // magnitude, altitude, range, NORAD ID, element age — so the value
            // column is uniformly monospaced-digit. It is also a half-step
            // heavier than its label, which is what makes the panel scan as
            // two columns rather than as a block of grey text.
            Text(value)
                .font(SkyType.captionNumeric)
                .foregroundStyle(SkyPalette.chromeText)
        }
    }
}
