//
//  TimeBarView.swift
//  Astronomy
//
//  The bottom time control — the Time Machine's surface.
//
//  Design constraints, in priority order:
//
//   1. **The sky stays dominant.** This is one glass pill at the bottom of a
//      full-screen sky. It grows by one short row of icon buttons, not a
//      transport deck.
//   2. **Never lie about what is on screen.** The single worst failure mode of
//      a time machine is the user forgetting they are in one. When simulated
//      time is not real time the clock turns amber, an "OFF REAL TIME" pill
//      appears, and "Now" lights up. That state is impossible to miss and
//      impossible to confuse with the live sky.
//   3. **Say where the sky stops being true.** Satellites are hidden a few
//      days from their element epoch, and the picker is clamped to the
//      planetary model's validity window. Both are stated in the bar rather
//      than left as silent absences.
//
//  Kept modular on purpose — the stepping, transport and picker are separate
//  small views, so a fuller Time Machine (events, twilight scrubber, saved
//  moments) can grow here without this file turning into a monolith.
//

import SwiftUI

struct TimeBarView: View {
    @Bindable var viewModel: SkyViewModel

    private var isLive: Bool { viewModel.time.isFollowingRealTime }

    var body: some View {
        GlassPanel {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    // Isolated deliberately. The clock text changes once a
                    // second; the controls beside it do not. Reading
                    // `currentDate` in *this* body would make the whole bar --
                    // two Menus and a DatePicker, which are not cheap to build
                    // -- rebuild every second, which is felt as a periodic
                    // hitch while panning. Reading it one level down confines
                    // the rebuild to the text.
                    TimeClockReadout(time: viewModel.time)
                    Divider().frame(height: 18).overlay(SkyPalette.panelStroke)
                    TimeStepControl(time: viewModel.time)
                    Divider().frame(height: 18).overlay(SkyPalette.panelStroke)
                    TimeTransportControl(time: viewModel.time)
                    TimeJumpControl(time: viewModel.time)
                    nowButton
                }

                if let caveat = viewModel.timeAccuracyCaveat {
                    Text(caveat)
                        .font(.system(size: 9))
                        .foregroundStyle(SkyPalette.warningAmber.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 520, alignment: .leading)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isLive)
    }

    private var nowButton: some View {
        Button("Now") {
            viewModel.time.resetToNow()
        }
        .buttonStyle(.plain)
        .font(.callout.weight(.medium))
        .foregroundStyle(isLive ? SkyPalette.chromeSecondaryText : SkyPalette.accentBlue)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(SkyPalette.accentBlue.opacity(isLive ? 0.08 : 0.22))
        )
        .help("Return to the real current time")
    }
}

// MARK: - Stepping

/// Hour / day / month / year stepping, forward and back.
///
/// One granularity menu between a pair of arrows rather than eight buttons:
/// the same footprint as a single stepper, and it keeps the chosen unit
/// visible, which is what the user actually needs to know before clicking.
private struct TimeStepControl: View {
    let time: TimeController

    enum Granularity: String, CaseIterable, Identifiable {
        case hour, day, month, year

        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var component: Calendar.Component {
            switch self {
            case .hour: return .hour
            case .day: return .day
            case .month: return .month
            case .year: return .year
            }
        }
    }

    @State private var granularity: Granularity = .day

    var body: some View {
        HStack(spacing: 4) {
            stepButton(-1, symbol: "chevron.left")

            Menu {
                ForEach(Granularity.allCases) { option in
                    Button(option.label) { granularity = option }
                }
            } label: {
                Text(granularity.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(SkyPalette.chromeText)
                    .frame(width: 44)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            stepButton(1, symbol: "chevron.right")
        }
    }

    private func stepButton(_ direction: Int, symbol: String) -> some View {
        Button {
            // Clamped to the ephemeris window: outside it the planets are not
            // modelled and the app will not pretend otherwise.
            let target = time.calendar.date(
                byAdding: granularity.component, value: direction, to: time.date
            ) ?? time.date
            time.jump(to: EphemerisService.clamped(target))
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SkyPalette.chromeText)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(direction < 0 ? "Back one \(granularity.rawValue)" : "Forward one \(granularity.rawValue)")
    }
}

// MARK: - Transport

/// Play/pause plus the playback speed.
private struct TimeTransportControl: View {
    let time: TimeController

    var body: some View {
        HStack(spacing: 6) {
            Button {
                time.togglePlaying()
            } label: {
                Image(systemName: time.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(SkyPalette.chromeText)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(time.isPlaying ? "Freeze simulated time" : "Resume simulated time")

            Menu {
                ForEach(TimeController.PlaybackRate.allCases) { rate in
                    Button(rate.longLabel) { time.setPlaybackRate(rate) }
                }
            } label: {
                Text(time.playbackRate.label)
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(
                        time.playbackRate == .realTime
                            ? SkyPalette.chromeSecondaryText
                            : SkyPalette.accentBlue
                    )
                    .frame(width: 34)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

// MARK: - Arbitrary instant

/// A calendar button opening a date/time picker for jumping anywhere in the
/// modelled window.
private struct TimeJumpControl: View {
    let time: TimeController

    @State private var isPresented = false
    @State private var draft = Date()

    var body: some View {
        Button {
            draft = EphemerisService.clamped(time.date)
            isPresented = true
        } label: {
            Image(systemName: "calendar")
                .font(.system(size: 12))
                .foregroundStyle(SkyPalette.chromeText)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Jump to a date and time")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                DatePicker(
                    "Go to",
                    selection: $draft,
                    in: EphemerisService.validDateRange,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.field)

                Text("Planetary positions are modelled for \(EphemerisService.validYearRange.lowerBound)–\(EphemerisService.validYearRange.upperBound); the picker is limited to that range.")
                    .font(.system(size: 9))
                    .foregroundStyle(SkyPalette.chromeSecondaryText)
                    .frame(maxWidth: 260, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button("Go") {
                        time.jump(to: EphemerisService.clamped(draft))
                        isPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
    }
}

// MARK: - Clock readout

/// The live clock text, isolated so that its once-a-second update invalidates
/// only itself.
///
/// This is the same lesson as the label overlay: with `@Observable` a view
/// depends on exactly the properties it reads, so reading a value that changes
/// every second from a body that also builds menus and a date picker makes all
/// of that rebuild every second. Splitting the frequently-changing read into
/// its own small view is what keeps the rest of the bar static.
private struct TimeClockReadout: View {
    let time: TimeController

    private var isLive: Bool { time.isFollowingRealTime }

    /// The system time zone's abbreviation *at the displayed instant*, so the
    /// label follows daylight-saving transitions rather than assuming a fixed
    /// offset. Falls back to the identifier if no abbreviation is available.
    private var timeZoneAbbreviation: String {
        let zone = TimeZone.current
        return zone.abbreviation(for: time.currentDate) ?? zone.identifier
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isLive ? "clock" : "clock.badge.exclamationmark")
                .foregroundStyle(isLive ? SkyPalette.accentBlue : SkyPalette.warningAmber)

            Text(time.currentDate, format: .dateTime.year().month().day().hour().minute().second())
                .font(.callout.monospacedDigit())
                .foregroundStyle(isLive ? SkyPalette.chromeText : SkyPalette.warningAmber)

            Text(timeZoneAbbreviation)
                .font(.caption.weight(.medium))
                .foregroundStyle(SkyPalette.chromeSecondaryText)

            if !isLive {
                Text("OFF REAL TIME")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(SkyPalette.warningAmber)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(SkyPalette.warningAmber.opacity(0.16)))
                    .overlay(Capsule().strokeBorder(SkyPalette.warningAmber.opacity(0.35), lineWidth: 1))
            }
        }
    }
}
