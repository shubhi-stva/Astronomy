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

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(object.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(SkyPalette.chromeText)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(SkyPalette.chromeSecondaryText)
                    }
                    .buttonStyle(.plain)
                }

                Text(kindLabel)
                    .font(.caption)
                    .foregroundStyle(SkyPalette.accentBlue)

                Divider().overlay(SkyPalette.panelStroke)

                if let designation = object.catalogDesignation, designation != object.name {
                    infoRow("Catalogue", designation)
                }
                if let satellite = object.satelliteDetails {
                    satelliteRows(satellite)
                } else {
                    infoRow("Magnitude", String(format: "%.2f", object.magnitude))
                }
                if let major = object.majorAxisArcmin {
                    infoRow("Size", angularSizeString(major: major, minor: object.minorAxisArcmin))
                }
                infoRow("Right Ascension", raString)
                infoRow("Declination", decString)
            }
        }
        .frame(width: 280)
    }

    private var kindLabel: String {
        switch object.kind {
        case .star: return "Star"
        case .sun: return "Sun"
        case .moon: return "Moon"
        case .planet: return "Planet"
        case .dwarfPlanet: return "Dwarf Planet"
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
    }

    private func illuminationText(_ illumination: TopocentricTransform.Illumination) -> String {
        switch illumination {
        case .sunlit: return "Sunlit"
        case .penumbra: return "Entering shadow"
        case .umbra: return "In Earth's shadow"
        }
    }

    private func elementAgeText(_ days: Double) -> String {
        if days < 0 { return String(format: "%.1f days ahead", -days) }
        if days < 1 { return String(format: "%.0f hours old", days * 24) }
        return String(format: "%.1f days old", days)
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
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(SkyPalette.chromeSecondaryText)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(SkyPalette.chromeText)
        }
    }
}
