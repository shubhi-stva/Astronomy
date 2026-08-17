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
            VStack(alignment: .trailing, spacing: 10) {
                Button {
                    if !isExpanded {
                        latitudeText = String(format: "%.4f", viewModel.location.currentLocation.latitudeDegrees)
                        longitudeText = String(format: "%.4f", viewModel.location.currentLocation.longitudeDegrees)
                    }
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "location")
                        Text(locationSummary)
                            .font(.callout.monospacedDigit())
                    }
                    .foregroundStyle(SkyPalette.chromeText)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Divider().overlay(SkyPalette.panelStroke)

                    VStack(alignment: .leading, spacing: 8) {
                        labeledField("Latitude", text: $latitudeText)
                        labeledField("Longitude", text: $longitudeText)

                        HStack {
                            Button("Use System Location") {
                                viewModel.location.requestSystemLocation()
                                isExpanded = false
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(SkyPalette.chromeSecondaryText)

                            Spacer()

                            Button("Apply") {
                                applyManualLocation()
                            }
                            .buttonStyle(.plain)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(SkyPalette.accentBlue)
                        }
                    }
                    .frame(width: 220)
                }
            }
        }
    }

    private var locationSummary: String {
        let loc = viewModel.location.currentLocation
        return String(format: "%.2f, %.2f", loc.latitudeDegrees, loc.longitudeDegrees)
    }

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(SkyPalette.chromeSecondaryText)
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
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
