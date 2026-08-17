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

                infoRow("Magnitude", String(format: "%.2f", object.magnitude))
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
        }
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
