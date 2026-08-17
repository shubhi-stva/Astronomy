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

    var body: some View {
        GlassPanel {
            HStack(spacing: 14) {
                Image(systemName: "clock")
                    .foregroundStyle(SkyPalette.accentBlue)

                Text(viewModel.time.currentDate, format: .dateTime.year().month().day().hour().minute().second())
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(SkyPalette.chromeText)

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
