//
//  CalendarPanelView.swift
//  Astronomy
//
//  The sky calendar: what is coming up, and one click to be there.
//
//  Three things the layout is doing on purpose:
//
//   * **Chronological, always.** A calendar that reordered itself by interest
//     would be a feed. The interest is expressed by the visibility dot on each
//     row and by the filter, not by moving rows around.
//   * **One line of substance per event.** Not a restatement of the title — the
//     separation, the distance, the rate. A row that says "Full Moon: the Moon
//     is full" is a row that has taught nobody anything.
//   * **Provenance shown.** Meteor showers carry a "tabulated" mark, because
//     they are the one class of entry the app did not derive, and the
//     difference is worth a glyph.
//

import SwiftUI

struct CalendarToggleView: View {
    @Bindable var viewModel: SkyViewModel

    var body: some View {
        Button {
            viewModel.isCalendarPresented.toggle()
        } label: {
            HStack(spacing: SkyMetrics.paddingTight) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .medium))
                Text("Calendar")
                    .font(SkyType.control)
            }
            .foregroundStyle(
                viewModel.isCalendarPresented ? SkyPalette.accentBlue : SkyPalette.chromeText
            )
            .padding(.horizontal, SkyMetrics.paddingPanel)
            .padding(.vertical, SkyMetrics.paddingSnug)
        }
        .buttonStyle(.plain)
        .chromePill()
    }
}

struct CalendarPanelView: View {
    @Bindable var viewModel: SkyViewModel

    /// When on, rows whose target never gets usefully high are hidden. Off by
    /// default: the first thing a calendar has to do is be complete, and a
    /// conjunction with the Sun is genuinely worth knowing has happened even
    /// though nobody will see it.
    @State private var observableOnly = false

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    private var events: [AstronomicalEvent] {
        guard observableOnly else { return viewModel.calendarEvents }
        return viewModel.calendarEvents.filter { event in
            guard let observability = event.observability else { return false }
            return observability.band > .notVisible
        }
    }

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: SkyMetrics.rowSpacing) {
                header

                Divider().overlay(SkyPalette.panelStroke)

                if viewModel.isComputingCalendar && viewModel.calendarEvents.isEmpty {
                    HStack(spacing: SkyMetrics.paddingSnug) {
                        ProgressView().controlSize(.small).tint(SkyPalette.chromeText)
                        Text("Solving for the next three months…")
                            .font(SkyType.caption)
                            .foregroundStyle(SkyPalette.chromeSecondaryText)
                    }
                } else if events.isEmpty {
                    Text("Nothing in the next three months clears the horizon from here.")
                        .font(SkyType.caption)
                        .foregroundStyle(SkyPalette.chromeSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: SkyMetrics.paddingSnug) {
                            ForEach(events) { event in
                                Button {
                                    viewModel.open(event: event)
                                } label: {
                                    row(event)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 440)
                }

                Divider().overlay(SkyPalette.panelStroke)
                footer
            }
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Text("Calendar")
                .font(SkyType.panelTitle)
                .foregroundStyle(SkyPalette.chromeText)
            Spacer()
            Toggle("Observable", isOn: $observableOnly)
                .toggleStyle(.checkbox)
                .font(SkyType.footnote)
                .foregroundStyle(SkyPalette.chromeSecondaryText)
            Button {
                viewModel.isCalendarPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(SkyPalette.chromeSecondaryText)
            }
            .buttonStyle(.plain)
        }
    }

    /// The two honest caveats, stated once at the bottom rather than repeated
    /// per row: where the shower data comes from, and what is missing.
    private var footer: some View {
        Text("Phases, seasons, oppositions and pairings are computed from this app's own ephemeris. Meteor shower rates and radiants are the IMO working list. Eclipses are not listed — see DATA_SOURCES.md.")
            .font(SkyType.footnote)
            .foregroundStyle(SkyPalette.chromeSecondaryText.opacity(0.75))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ event: AstronomicalEvent) -> some View {
        HStack(alignment: .top, spacing: SkyMetrics.paddingSnug) {
            visibilityDot(event)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: SkyMetrics.paddingTight) {
                    Image(systemName: event.kind.symbolName)
                        .font(.system(size: 10))
                        .foregroundStyle(SkyPalette.chromeSecondaryText)
                    Text(event.title)
                        .font(SkyType.body)
                        .foregroundStyle(SkyPalette.chromeText)
                    if event.provenance == .tabulated {
                        Text("TABULATED")
                            .font(SkyType.badge)
                            .tracking(SkyType.badgeSpec.tracking)
                            .foregroundStyle(SkyPalette.chromeSecondaryText.opacity(0.7))
                    }
                }

                Text(whenText(event))
                    .font(SkyType.captionNumeric)
                    .foregroundStyle(SkyPalette.accentBlue.opacity(0.9))

                Text(event.detail)
                    .font(SkyType.footnote)
                    .foregroundStyle(SkyPalette.chromeSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let note = observabilityNote(event) {
                    Text(note)
                        .font(SkyType.footnoteNumeric)
                        .foregroundStyle(SkyPalette.chromeSecondaryText.opacity(0.8))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// The date, and the time only where the time is meaningful.
    ///
    /// Oppositions and conjunctions are printed to the day because
    /// `PlanetPosition`'s few arcminutes become hours of timing error at an
    /// elongation extremum — see `PlanetaryEvents`. Printing a minute there
    /// would be claiming a precision this app does not have.
    private func whenText(_ event: AstronomicalEvent) -> String {
        let day = Self.dayFormatter.string(from: event.date)
        switch event.kind {
        case .opposition, .conjunction, .greatestElongation:
            return day
        default:
            return "\(day) · \(Self.timeFormatter.string(from: event.date))"
        }
    }

    private func observabilityNote(_ event: AstronomicalEvent) -> String? {
        guard let observability = event.observability else { return nil }
        switch observability.circumstance {
        case .neverUp:
            return "Never rises from here."
        case .alwaysUp:
            return "Circumpolar — up all night, \(Int(observability.peakAltitudeDegrees.rounded()))° at best."
        case .risesAndSets:
            let peak = Int(observability.peakAltitudeDegrees.rounded())
            guard peak > 0 else { return "Below the horizon all night from here." }
            let when = observability.peakIsInDarkness ? "in darkness" : "before dark"
            return "Reaches \(peak)° \(when), at \(Self.timeFormatter.string(from: JulianDate.date(fromJulianDay: observability.peakJulianDay)))."
        }
    }

    /// A four-state dot rather than a word: the band is a rating, and a column
    /// of the word "Excellent" would shout louder than the event titles.
    @ViewBuilder
    private func visibilityDot(_ event: AstronomicalEvent) -> some View {
        Circle()
            .fill(dotColor(event))
            .frame(width: 6, height: 6)
            .padding(.top, 5)
            .help(event.observability?.band.displayName ?? "Not applicable")
    }

    private func dotColor(_ event: AstronomicalEvent) -> Color {
        guard let band = event.observability?.band else {
            return SkyPalette.chromeSecondaryText.opacity(0.25)
        }
        switch band {
        case .excellent: return SkyPalette.accentBlue
        case .good: return SkyPalette.accentBlue.opacity(0.6)
        case .difficult: return SkyPalette.warningAmber.opacity(0.7)
        case .notVisible: return SkyPalette.chromeSecondaryText.opacity(0.3)
        }
    }
}
