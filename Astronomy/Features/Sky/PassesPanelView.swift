//
//  PassesPanelView.swift
//  Astronomy
//
//  Upcoming satellite passes: when the ISS (and whatever satellite is
//  selected) crosses the sky, from where to where, how high, and whether it
//  will actually be visible.
//
//  The panel answers the one question a satellite layer otherwise cannot:
//  "when do I go outside and where do I look?". A marker on a sky chart says
//  where something is *now*; a pass list says where it will be, which is the
//  only form the answer is useful in, because the good passes are the ones you
//  have to be ready for.
//
//  Same restrained chrome as the other dashboards: one `GlassPanel`, the
//  existing type scale, a fixed width. `SatellitePassPredictor` does the
//  finding; this file only arranges it.
//

import SwiftUI

/// Top-bar pill, next to the other panel triggers.
struct PassesToggleView: View {
    @Bindable var viewModel: SkyViewModel

    var body: some View {
        Button {
            viewModel.isPassesPanelPresented.toggle()
        } label: {
            HStack(spacing: SkyMetrics.paddingTight) {
                Image(systemName: "airplane.departure")
                    .font(.system(size: 11, weight: .medium))
                Text("Passes")
                    .font(SkyType.control)
            }
            .foregroundStyle(
                viewModel.isPassesPanelPresented ? SkyPalette.accentBlue : SkyPalette.chromeText
            )
            .padding(.horizontal, SkyMetrics.paddingPanel)
            .padding(.vertical, SkyMetrics.paddingSnug)
        }
        .buttonStyle(.plain)
        .chromePill()
        .help("Upcoming satellite passes (P)")
    }
}

struct PassesPanelView: View {
    @Bindable var viewModel: SkyViewModel

    private func clock(_ julianDay: Double) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = viewModel.location.timeZone
        formatter.dateFormat = "EEE HH:mm:ss"
        return formatter.string(from: JulianDate.date(fromJulianDay: julianDay))
    }

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: SkyMetrics.rowSpacing) {
                header

                Divider().overlay(SkyPalette.panelStroke)

                if viewModel.isComputingPasses && viewModel.passes.isEmpty {
                    HStack(spacing: SkyMetrics.paddingSnug) {
                        ProgressView().controlSize(.small).tint(SkyPalette.chromeText)
                        Text("Searching the next two days…")
                            .font(SkyType.caption)
                            .foregroundStyle(SkyPalette.chromeSecondaryText)
                    }
                } else if viewModel.passes.isEmpty {
                    // Two days with nothing over 10° is a real answer, and a
                    // common one at high latitude or for a satellite whose
                    // ground track has drifted away. Say so rather than
                    // showing an empty box.
                    Text("No pass climbs above 10° in the next two days.")
                        .font(SkyType.caption)
                        .foregroundStyle(SkyPalette.chromeSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: SkyMetrics.clusterSpacing) {
                            ForEach(viewModel.passes) { pass in
                                passRow(pass)
                            }
                        }
                    }
                    .frame(maxHeight: 380)
                }

                Text("Times are for \(viewModel.location.placeName ?? "your location"). Click a pass to fly the time machine to it.")
                    .font(SkyType.footnote)
                    .foregroundStyle(SkyPalette.chromeSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 330)
    }

    private var header: some View {
        HStack {
            Text("Satellite passes")
                .font(SkyType.panelTitle)
                .foregroundStyle(SkyPalette.chromeText)
            Spacer()
            if viewModel.isComputingPasses && !viewModel.passes.isEmpty {
                ProgressView().controlSize(.small).tint(SkyPalette.chromeSecondaryText)
            }
            Button {
                viewModel.isPassesPanelPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(SkyPalette.chromeSecondaryText)
            }
            .buttonStyle(.plain)
        }
    }

    /// One pass: name and peak altitude, the clock times, and the rise/set
    /// bearings — which are what you actually stand outside and use.
    private func passRow(_ pass: SatellitePass) -> some View {
        Button {
            viewModel.open(pass: pass)
        } label: {
            VStack(alignment: .leading, spacing: SkyMetrics.paddingTight) {
                HStack(alignment: .firstTextBaseline) {
                    Text(pass.name)
                        .font(SkyType.control)
                        .foregroundStyle(SkyPalette.chromeText)
                    Spacer()
                    Text(String(format: "%.0f° high", pass.peakHorizontal.altitudeDegrees))
                        .font(SkyType.captionNumeric)
                        .foregroundStyle(SkyPalette.chromeSecondaryText)
                }

                Text("\(clock(pass.riseJulianDay)) · \(Int(pass.durationSeconds / 60)) min")
                    .font(SkyType.captionNumeric)
                    .foregroundStyle(SkyPalette.chromeText)

                Text(bearings(pass))
                    .font(SkyType.caption)
                    .foregroundStyle(SkyPalette.chromeSecondaryText)

                Text(visibilityNote(pass))
                    .font(SkyType.footnote)
                    .foregroundStyle(
                        pass.isVisible ? SkyPalette.accentBlue : SkyPalette.chromeSecondaryText
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "Rises NW → peaks SSE → sets E", the shape of the pass across the sky.
    private func bearings(_ pass: SatellitePass) -> String {
        let rise = InfoPanelView.compassPoint(pass.riseAzimuthDegrees)
        let peak = InfoPanelView.compassPoint(pass.peakHorizontal.azimuthDegrees)
        let set = InfoPanelView.compassPoint(pass.setAzimuthDegrees)
        return "Rises \(rise) → peaks \(peak) → sets \(set)"
    }

    /// Why a pass is or is not worth going outside for.
    ///
    /// The distinction is real and has two independent halves: the satellite
    /// must be in sunlight (otherwise it is a dark object against a dark sky),
    /// and the observer must be in darkness (otherwise it is lost in a bright
    /// one). Both are stated rather than collapsed into "not visible", because
    /// a radio operator wants the daylight pass and a photographer does not.
    private func visibilityNote(_ pass: SatellitePass) -> String {
        if pass.isVisible { return "Visible — sunlit against a dark sky." }
        if pass.isSunlitAtPeak { return "Sunlit, but your sky is too bright to see it." }
        return "In the Earth's shadow; radio only."
    }
}
