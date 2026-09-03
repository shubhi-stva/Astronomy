//
//  NightVisionToggleView.swift
//  Astronomy
//
//  The chrome half of the night-vision switch: one icon-only pill in the
//  top-right cluster. Icon-only because the cluster already carries two
//  labelled pills, and a third word there starts to read as a toolbar.
//

import SwiftUI

struct NightVisionToggleView: View {
    let controller: NightVisionController

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: NightVision.transitionDuration)) {
                controller.toggle()
            }
        } label: {
            Image(systemName: controller.isEnabled ? "eye.fill" : "eye")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(
                    controller.isEnabled ? SkyPalette.accentBlue : SkyPalette.chromeText
                )
                .frame(width: SkyMetrics.iconButtonSize, height: SkyMetrics.iconButtonSize)
                .padding(.horizontal, SkyMetrics.paddingSnug)
                .padding(.vertical, SkyMetrics.paddingTight)
        }
        .buttonStyle(.plain)
        .chromePill()
        .help(controller.isEnabled ? "Night vision on (N)" : "Night vision (N)")
        .accessibilityLabel("Night vision")
    }
}
