//
//  LocationControlView.swift
//  Astronomy
//
//  Small floating control for manual latitude/longitude entry, defaulting
//  to New York if no location has been set. Collapsed to a single button
//  showing the current coordinates; expands to an editable form.
//

import SwiftUI

struct LocationControlView: View {
    @Bindable var viewModel: SkyViewModel
    @Binding var isExpanded: Bool

    @State private var latitudeText: String = ""
    @State private var longitudeText: String = ""

    var body: some View {
        GlassPanel {
            VStack(alignment: .trailing, spacing: SkyMetrics.paddingSnug) {
                Button {
                    if !isExpanded {
                        latitudeText = String(format: "%.4f", viewModel.location.currentLocation.latitudeDegrees)
                        longitudeText = String(format: "%.4f", viewModel.location.currentLocation.longitudeDegrees)
                    }
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: SkyMetrics.rowSpacing) {
                        Image(systemName: "location")
                            .font(.system(size: 11, weight: .medium))
                        // Always monospaced-digit now, rather than only when
                        // the summary happens to be coordinates. The previous
                        // conditional meant the control changed typeface the
                        // moment reverse-geocoding resolved, which was a
                        // visible flicker on a control the user was not
                        // interacting with. One face, and the coordinate case
                        // still gets its stable columns.
                        Text(locationSummary)
                            .font(SkyType.bodyNumeric)
                    }
                    .foregroundStyle(SkyPalette.chromeText)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Divider().overlay(SkyPalette.panelStroke)

                    VStack(alignment: .leading, spacing: SkyMetrics.paddingSnug) {
                        if let statusNote {
                            Text(statusNote)
                                .font(SkyType.footnote)
                                .foregroundStyle(SkyPalette.chromeSecondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        labeledField("Latitude", text: $latitudeText)
                        labeledField("Longitude", text: $longitudeText)

                        HStack {
                            Button("Use System Location") {
                                viewModel.location.requestSystemLocation()
                                isExpanded = false
                            }
                            .buttonStyle(.plain)
                            .font(SkyType.control)
                            .foregroundStyle(SkyPalette.chromeSecondaryText)

                            Spacer()

                            Button("Apply") {
                                applyManualLocation()
                            }
                            .buttonStyle(.plain)
                            .font(SkyType.control)
                            .foregroundStyle(SkyPalette.accentBlue)
                        }
                    }
                    .frame(width: 220)
                }
            }
        }
    }

    /// Reverse-geocoded place name once it resolves; formatted coordinates
    /// until then (and permanently, if geocoding fails or is offline). States
    /// where we don't actually know where the user is say so, rather than
    /// showing a placeholder that reads like a real position.
    private var locationSummary: String {
        switch viewModel.location.source {
        case .fallback:
            return "Set location"
        case .resolving:
            return "Locating…"
        case .unavailable:
            return "Set location"
        case .system, .manual:
            if let place = viewModel.location.placeName, !place.isEmpty {
                return place
            }
            let loc = viewModel.location.currentLocation
            return String(format: "%.2f, %.2f", loc.latitudeDegrees, loc.longitudeDegrees)
        }
    }

    /// Explains why automatic location isn't in use, shown only in the
    /// expanded form so the collapsed control stays minimal.
    private var statusNote: String? {
        if case .unavailable(let reason) = viewModel.location.source {
            return reason
        }
        return nil
    }

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(SkyType.sectionLabel)
                .tracking(SkyType.sectionLabelSpec.tracking)
                .foregroundStyle(SkyPalette.chromeSecondaryText)
            // Latitude and longitude to four decimal places: the one place in
            // the app where the user *edits* a number, so a stable digit width
            // matters while typing as much as while reading.
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .font(SkyType.bodyNumeric)
                .padding(.horizontal, SkyMetrics.rowSpacing)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: SkyMetrics.radiusInner, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SkyMetrics.radiusInner, style: .continuous)
                        .strokeBorder(SkyPalette.panelStroke, lineWidth: SkyMetrics.strokeWidth)
                )
                .foregroundStyle(SkyPalette.chromeText)
        }
    }

    private func applyManualLocation() {
        guard let lat = Double(latitudeText), let lon = Double(longitudeText),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return }
        viewModel.location.setManualLocation(latitudeDegrees: lat, longitudeDegrees: lon)
        isExpanded = false
    }
}
