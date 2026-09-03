//
//  TonightPanelView.swift
//  Astronomy
//
//  The "Tonight" dashboard: sunset and the twilight boundaries, the Moon, the
//  planets that are up, and the best deep-sky targets — each with a visibility
//  band and the constraint that produced it.
//
//  Restrained floating chrome, like everything else here: one `GlassPanel`, the
//  existing `SkyType`/`SkyMetrics` scale, no new colours beyond the four band
//  tints, and a fixed width so it never spreads across the sky. The reasoning
//  behind every number it shows lives in `VisibilityRating`; this file only
//  arranges it.
//

import SwiftUI

/// Small trigger that lives in the top bar next to the other pills.
struct TonightToggleView: View {
    @Bindable var viewModel: SkyViewModel

    var body: some View {
        Button {
            viewModel.isTonightPanelPresented.toggle()
        } label: {
            HStack(spacing: SkyMetrics.paddingTight) {
                Image(systemName: "moon.stars")
                    .font(.system(size: 11, weight: .medium))
                Text("Tonight")
                    .font(SkyType.control)
            }
            .foregroundStyle(
                viewModel.isTonightPanelPresented
                    ? SkyPalette.accentBlue
                    : SkyPalette.chromeText
            )
            .padding(.horizontal, SkyMetrics.paddingPanel)
            .padding(.vertical, SkyMetrics.paddingSnug)
        }
        .buttonStyle(.plain)
        .chromePill()
    }
}

struct TonightPanelView: View {
    @Bindable var viewModel: SkyViewModel

    /// One formatter for the whole panel. Times are local wall-clock, which is
    /// the only form in which "sunset" is a useful sentence.
    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private func clock(_ julianDay: Double?) -> String {
        guard let julianDay else { return "—" }
        return Self.time.string(from: JulianDate.date(fromJulianDay: julianDay))
    }

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: SkyMetrics.rowSpacing) {
                header

                if let report = viewModel.tonightReport {
                    Divider().overlay(SkyPalette.panelStroke)
                    ScrollView {
                        VStack(alignment: .leading, spacing: SkyMetrics.clusterSpacing) {
                            twilight(report.night)
                            moon(report.moon, night: report.night)
                            if !report.planets.isEmpty {
                                targets("Planets up tonight", report.planets)
                            }
                            if report.deepSky.isEmpty {
                                section("Deep sky")
                                Text(report.night.astronomicalNightOccurs
                                     ? "Nothing in the catalogue clears the horizon well enough tonight."
                                     : "No astronomical darkness tonight, so no deep-sky target is rated.")
                                    .font(SkyType.caption)
                                    .foregroundStyle(SkyPalette.chromeSecondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                targets("Best deep-sky targets", report.deepSky)
                            }
                        }
                    }
                    .frame(maxHeight: 420)
                } else {
                    HStack(spacing: SkyMetrics.paddingSnug) {
                        ProgressView().controlSize(.small).tint(SkyPalette.chromeText)
                        Text("Working out tonight's sky…")
                            .font(SkyType.caption)
                            .foregroundStyle(SkyPalette.chromeSecondaryText)
                    }
                }
            }
        }
        .frame(width: 330)
    }

    private var header: some View {
        HStack {
            Text("Tonight")
                .font(SkyType.panelTitle)
                .foregroundStyle(SkyPalette.chromeText)
            Spacer()
            Button {
                viewModel.isTonightPanelPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(SkyPalette.chromeSecondaryText)
            }
            .buttonStyle(.plain)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(SkyType.sectionLabel)
            .tracking(SkyType.sectionLabelSpec.tracking)
            .foregroundStyle(SkyPalette.accentBlue.opacity(0.9))
    }

    // MARK: Twilight

    @ViewBuilder
    private func twilight(_ night: NightWindow) -> some View {
        VStack(alignment: .leading, spacing: SkyMetrics.rowSpacing) {
            section("Sunset and twilight")
            row("Sunset", clock(night.sun.eveningJulianDay))
            row("Civil dusk", clock(night.civil.eveningJulianDay))
            row("Nautical dusk", clock(night.nautical.eveningJulianDay))
            row("Astronomical dusk", clock(night.astronomical.eveningJulianDay))
            row("Astronomical dawn", clock(night.astronomical.morningJulianDay))
            row("Sunrise", clock(night.sun.morningJulianDay))
            if night.astronomicalNightOccurs {
                row("True darkness", String(format: "%.1f h", night.darkHours))
            } else {
                // The honest high-latitude answer, said plainly rather than
                // shown as a dash the reader has to interpret.
                Text(night.sun.eveningJulianDay == nil
                     ? "The Sun does not set tonight."
                     : "The Sun never reaches −18°, so there is no astronomical darkness tonight.")
                    .font(SkyType.footnote)
                    .foregroundStyle(SkyPalette.warningAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Moon

    @ViewBuilder
    private func moon(_ moon: MoonTonight, night: NightWindow) -> some View {
        VStack(alignment: .leading, spacing: SkyMetrics.rowSpacing) {
            section("Moon")
            row("Phase", moon.phaseName)
            row("Illuminated", String(format: "%.0f%%", moon.illuminatedFraction * 100))
            switch moon.circumstance {
            case .risesAndSets:
                row("Rise", clock(moon.riseJulianDay))
                row("Set", clock(moon.setJulianDay))
            case .alwaysUp:
                row("Rise / set", "Up all night")
            case .neverUp:
                row("Rise / set", "Below the horizon")
            }
            row("Highest", String(format: "%.0f° at %@",
                                  moon.transitAltitudeDegrees, clock(moon.transitJulianDay)))
            if night.astronomicalNightOccurs {
                // The number the ratings below actually consume, shown because
                // it is what explains a whole column of "Moonlight".
                row("Up during darkness", String(format: "%.0f%%", moon.upFractionOfDarkWindow * 100))
            }
        }
    }

    // MARK: Targets

    @ViewBuilder
    private func targets(_ title: String, _ list: [TonightTarget]) -> some View {
        VStack(alignment: .leading, spacing: SkyMetrics.rowSpacing) {
            section(title)
            ForEach(list) { target in
                Button {
                    viewModel.selectAndFocus(targetID: target.id)
                } label: {
                    targetRow(target)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func targetRow(_ target: TonightTarget) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: SkyMetrics.paddingSnug) {
                Text(target.name)
                    .font(SkyType.body)
                    .foregroundStyle(SkyPalette.chromeText)
                    .lineLimit(1)
                Spacer(minLength: SkyMetrics.paddingSnug)
                Text(target.visibility.band.displayName)
                    .font(SkyType.badge)
                    .tracking(SkyType.badgeSpec.tracking)
                    .foregroundStyle(Self.tint(target.visibility.band))
            }
            HStack(spacing: SkyMetrics.paddingSnug) {
                Text(subtitle(target))
                    .font(SkyType.footnoteNumeric)
                    .foregroundStyle(SkyPalette.chromeSecondaryText)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    /// The row's second line is the *derivation*, not decoration: peak altitude
    /// and airmass, hours in darkness, and the constraint that set the band.
    private func subtitle(_ target: TonightTarget) -> String {
        let visibility = target.visibility
        var parts: [String] = []
        if let type = target.typeDescription { parts.append(type) }
        parts.append(String(format: "mag %.1f", target.magnitude))
        parts.append(String(format: "%.0f° (X %.2f)",
                            visibility.peakAltitudeDegrees, visibility.airmassAtPeak))
        parts.append(String(format: "%.1f h dark", visibility.hoursInDarkness))
        parts.append("limit: \(visibility.limitingFactor.rawValue)")
        return parts.joined(separator: " · ")
    }

    /// One tint per band. Reused from the existing palette rather than
    /// introducing a new ramp: the accent for the best, the ordinary chrome
    /// text for the middle, the existing warning amber for the marginal.
    private static func tint(_ band: VisibilityBand) -> Color {
        switch band {
        case .excellent: return SkyPalette.accentBlue
        case .good: return SkyPalette.chromeText
        case .difficult: return SkyPalette.warningAmber
        case .notVisible: return SkyPalette.chromeSecondaryText
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: SkyMetrics.paddingSnug) {
            Text(label)
                .font(SkyType.caption)
                .foregroundStyle(SkyPalette.chromeSecondaryText)
            Spacer(minLength: SkyMetrics.paddingSnug)
            Text(value)
                .font(SkyType.captionNumeric)
                .foregroundStyle(SkyPalette.chromeText)
        }
    }
}
