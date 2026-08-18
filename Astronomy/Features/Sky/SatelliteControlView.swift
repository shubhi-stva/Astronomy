//
//  SatelliteControlView.swift
//  Astronomy
//
//  The satellite layer's two controls, in the same collapsed-pill idiom the
//  search field uses so it stays out of the sky.
//
//  There are only two, and the choice of which two is the whole design:
//
//   * **Satellites** turns the layer off entirely, because some nights the
//     answer to "what is that moving dot" is "I do not want to know".
//   * **Show all** switches from the honest default — the objects that are
//     genuinely visible from here, right now — to the whole 16,000-object
//     catalogue. The second is a fine thing to look at once, and a terrible
//     default, so it is opt-in and additionally fades in with zoom.
//
//  A live count sits underneath, because "how many satellites are up there
//  right now" turns out to be the question people actually ask of this feature.
//

import SwiftUI

struct SatelliteControlView: View {
    @Bindable var viewModel: SkyViewModel

    @State private var isExpanded = false

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(
                            viewModel.satellitesEnabled
                                ? SkyPalette.satelliteLabel
                                : SkyPalette.chromeSecondaryText
                        )
                        .onTapGesture { isExpanded.toggle() }

                    if isExpanded {
                        Text("Satellites")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(SkyPalette.chromeText)
                        Spacer(minLength: 12)
                        Toggle("", isOn: $viewModel.satellitesEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                }

                if isExpanded {
                    Divider()
                        .overlay(SkyPalette.panelStroke)
                        .padding(.vertical, 8)

                    HStack {
                        Text("Show all")
                            .font(.caption)
                            .foregroundStyle(SkyPalette.chromeSecondaryText)
                        Spacer(minLength: 12)
                        Toggle("", isOn: $viewModel.showAllSatellites)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .disabled(!viewModel.satellitesEnabled)
                    }

                    Text(statusText)
                        .font(.system(size: 9))
                        .foregroundStyle(SkyPalette.chromeSecondaryText.opacity(0.75))
                        .padding(.top, 6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: isExpanded ? 190 : 16)
        }
        .contentShape(Rectangle())
        .onTapGesture { isExpanded = true }
        .animation(.easeInOut(duration: 0.22), value: isExpanded)
    }

    /// "142 visible of 16,079 tracked" — the second number is the honest
    /// denominator, the first is what you can actually see.
    private var statusText: String {
        let tracked = viewModel.satelliteDescriptors.count
        guard tracked > 0 else { return "Loading element sets…" }
        return "\(viewModel.visibleSatelliteCount) visible of \(tracked.formatted()) tracked"
    }
}
