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
                HStack(spacing: SkyMetrics.paddingSnug) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(
                            viewModel.satellitesEnabled
                                ? SkyPalette.satelliteLabel
                                : SkyPalette.chromeSecondaryText
                        )
                        .onTapGesture { isExpanded.toggle() }

                    if isExpanded {
                        Text("Satellites")
                            .font(SkyType.body)
                            .foregroundStyle(SkyPalette.chromeText)
                        Spacer(minLength: SkyMetrics.clusterSpacing)
                        Toggle("", isOn: $viewModel.satellitesEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                }

                if isExpanded {
                    Divider()
                        .overlay(SkyPalette.panelStroke)
                        .padding(.vertical, SkyMetrics.paddingSnug)

                    HStack {
                        Text("Show all")
                            .font(SkyType.body)
                            .foregroundStyle(SkyPalette.chromeSecondaryText)
                        Spacer(minLength: SkyMetrics.clusterSpacing)
                        Toggle("", isOn: $viewModel.showAllSatellites)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .disabled(!viewModel.satellitesEnabled)
                    }

                    // Monospaced-digit and it earns it: the visible count
                    // recomputes as the sky moves, so "142 visible of 16,079
                    // tracked" would otherwise re-flow every few seconds under
                    // a control nobody is touching.
                    Text(statusText)
                        .font(SkyType.footnoteNumeric)
                        .foregroundStyle(SkyPalette.chromeSecondaryText.opacity(0.75))
                        .padding(.top, SkyMetrics.rowSpacing)
                        .fixedSize(horizontal: false, vertical: true)

                    // Element staleness, stated rather than implied. Drawn
                    // positions degrade gradually as elements age; the user is
                    // told how far along that curve they are instead of being
                    // left to trust a marker that may be degrees out.
                    if let staleness = stalenessText {
                        Text(staleness)
                            .font(SkyType.footnoteNumeric)
                            .foregroundStyle(stalenessColor)
                            .padding(.top, SkyMetrics.paddingTight)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // A refresh that keeps failing used to be visible only in
                    // the system log, which is exactly how the app came to run
                    // for weeks on elements it shipped with.
                    if let failure = refreshFailureText {
                        Text(failure)
                            .font(SkyType.footnoteNumeric)
                            .foregroundStyle(SkyPalette.chromeSecondaryText.opacity(0.75))
                            .padding(.top, SkyMetrics.paddingTight)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
        // Under the time machine the honest answer is not a count. Element sets
        // are only meaningful within a few days of their epoch, so beyond that
        // the layer suppresses itself and says so rather than reporting a
        // number that describes nothing. See `SatelliteAccuracy`.
        if viewModel.satellitesSuppressedBySimulatedTime {
            let days = Int(SatelliteAccuracy.maximumElementSetAgeDays)
            return "Hidden at this time: orbital elements are only valid within ±\(days) days of their epoch."
        }
        return "\(viewModel.visibleSatelliteCount) visible of \(tracked.formatted()) tracked"
    }

    /// "Elements 7.7 days old — positions unreliable…". Absent while the
    /// elements are fresh, because then there is nothing to say, and absent
    /// while the layer is suppressed, because then `statusText` has already
    /// said the stronger thing.
    private var stalenessText: String? {
        guard !viewModel.satelliteDescriptors.isEmpty,
              !viewModel.satellitesSuppressedBySimulatedTime,
              let caveat = viewModel.satelliteStaleness.caveat else { return nil }
        let age = viewModel.satelliteElementAgeDays
        return String(format: "Elements %.1f days old. %@", age, caveat)
    }

    private var stalenessColor: Color {
        viewModel.satelliteStaleness == .unreliable
            ? SkyPalette.warningAmber
            : SkyPalette.chromeSecondaryText.opacity(0.85)
    }

    /// Only shown once the app has actually failed to fetch, and phrased as
    /// what it is: the app is still showing what it already had.
    private var refreshFailureText: String? {
        let status = viewModel.satelliteRefreshStatus
        guard status.isFailing else { return nil }
        return "Could not fetch newer element sets (\(status.consecutiveFailures) attempt\(status.consecutiveFailures == 1 ? "" : "s")). Still using the elements above; retrying."
    }
}
