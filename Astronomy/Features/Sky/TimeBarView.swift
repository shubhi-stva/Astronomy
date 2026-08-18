//
//  TimeBarView.swift
//  Astronomy
//
//  Bottom floating translucent bar: current date/time (live) plus a "Now"
//  button that resets TimeController to system time.
//

import SwiftUI

struct TimeBarView: View {
    @Bindable var viewModel: SkyViewModel

    /// The system time zone's abbreviation *at the displayed instant*, so the
    /// label follows daylight-saving transitions rather than assuming a fixed
    /// offset. Falls back to the identifier if no abbreviation is available.
    private var timeZoneAbbreviation: String {
        let zone = TimeZone.current
        let date = viewModel.time.currentDate
        return zone.abbreviation(for: date) ?? zone.identifier
    }

    var body: some View {
        GlassPanel {
            HStack(spacing: 14) {
                Image(systemName: "clock")
                    .foregroundStyle(SkyPalette.accentBlue)

                Text(viewModel.time.currentDate, format: .dateTime.year().month().day().hour().minute().second())
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(SkyPalette.chromeText)

                // Abbreviation for the system's current time zone, resolved
                // per-instant so daylight saving is reflected automatically
                // (e.g. PDT in August, PST in December) with nothing hard-coded.
                Text(timeZoneAbbreviation)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(SkyPalette.chromeSecondaryText)

                Button("Now") {
                    viewModel.time.resetToNow()
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.medium))
                .foregroundStyle(SkyPalette.accentBlue)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(SkyPalette.accentBlue.opacity(0.15))
                )
            }
        }
    }
}
