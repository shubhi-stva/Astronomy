//
//  CommandPaletteView.swift
//  Astronomy
//
//  ⌘K. Type, arrow, return.
//
//  Placed a third of the way down the window rather than centred: a centred
//  panel puts the list over the middle of the sky, and the sky is the content.
//  A third down keeps the horizon and the lower chrome visible behind it.
//
//  Everything is reachable from the keyboard and nothing requires the mouse.
//  The hover state exists only so that a user who has reached for the trackpad
//  is not then told to put it down.
//

import SwiftUI

/// The always-present overlay. Reads `palette.isPresented` here rather than in
/// `SkyView`, so opening and closing the palette invalidates this view and
/// nothing else — in particular not the Metal representable. See
/// `CommandPaletteModel`.
struct CommandPaletteOverlay: View {
    @Bindable var viewModel: SkyViewModel

    var body: some View {
        if viewModel.palette.isPresented {
            CommandPaletteView(viewModel: viewModel)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

struct CommandPaletteView: View {
    @Bindable var viewModel: SkyViewModel
    @FocusState private var isFieldFocused: Bool
    @State private var hoveredID: String?

    private var palette: CommandPaletteModel { viewModel.palette }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
                .frame(height: 90)

            GlassPanel {
                VStack(alignment: .leading, spacing: SkyMetrics.paddingSnug) {
                    field

                    if !palette.commands.isEmpty {
                        Divider().overlay(SkyPalette.panelStroke)
                        list
                    } else if palette.isLocationMode {
                        emptyNote(
                            palette.isGeocoding
                                ? "Looking that up…"
                                : "Type at least three letters of a place name."
                        )
                    } else {
                        emptyNote("Nothing matches that.")
                    }

                    Divider().overlay(SkyPalette.panelStroke)
                    hints
                }
            }
            .frame(width: 460)
            // A palette is modal in intent even though it does not block the
            // sky: a shadow one step heavier than the other panels is what says
            // "this is in front" without dimming everything behind it, which
            // the user has consistently rejected as heavy.
            .shadow(color: .black.opacity(0.45), radius: 28, y: 12)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            isFieldFocused = true
            palette.refresh(context: viewModel.paletteContext())
        }
        .onChange(of: palette.query) { _, _ in
            palette.refresh(context: viewModel.paletteContext())
        }
        .onChange(of: palette.placeMatches) { _, _ in
            palette.refresh(context: viewModel.paletteContext())
        }
    }

    // MARK: - Field

    private var field: some View {
        HStack(spacing: SkyMetrics.paddingSnug) {
            Image(systemName: palette.isLocationMode ? "mappin.and.ellipse" : "command")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SkyPalette.chromeSecondaryText)

            TextField(
                palette.isLocationMode ? "Place name…" : "Search commands, objects and events…",
                text: Binding(
                    get: { palette.query },
                    set: { palette.query = $0 }
                )
            )
            .textFieldStyle(.plain)
            .font(SkyType.panelTitle)
            .foregroundStyle(SkyPalette.chromeText)
            .focused($isFieldFocused)
            .onKeyPress(.downArrow) { palette.moveSelection(by: 1); return .handled }
            .onKeyPress(.upArrow) { palette.moveSelection(by: -1); return .handled }
            .onKeyPress(.return) { runSelected(); return .handled }
            .onKeyPress(.escape) { palette.escape(); return .handled }
            .onKeyPress(.tab) { palette.moveSelection(by: 1); return .handled }

            if palette.isGeocoding {
                ProgressView().controlSize(.small).tint(SkyPalette.chromeSecondaryText)
            }
        }
    }

    // MARK: - List

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(palette.commands.enumerated()), id: \.element.id) { index, command in
                row(command, index: index)
            }
        }
    }

    private func row(_ command: PaletteCommand, index: Int) -> some View {
        let isSelected = index == palette.selectedIndex
        return Button {
            palette.select(index: index)
            runSelected()
        } label: {
            HStack(spacing: SkyMetrics.paddingSnug) {
                Image(systemName: command.symbolName)
                    .font(.system(size: 11))
                    .frame(width: 16)
                    .foregroundStyle(
                        isSelected ? SkyPalette.accentBlue : SkyPalette.chromeSecondaryText
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(command.title)
                        .font(SkyType.body)
                        .foregroundStyle(SkyPalette.chromeText)
                    if let subtitle = command.subtitle {
                        Text(subtitle)
                            .font(SkyType.footnote)
                            .foregroundStyle(SkyPalette.chromeSecondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Text(command.category.displayName.uppercased())
                    .font(SkyType.badge)
                    .tracking(SkyType.badgeSpec.tracking)
                    .foregroundStyle(SkyPalette.chromeSecondaryText.opacity(0.55))
            }
            .padding(.horizontal, SkyMetrics.paddingSnug)
            .padding(.vertical, SkyMetrics.rowSpacing)
            .background(
                RoundedRectangle(cornerRadius: SkyMetrics.radiusInner, style: .continuous)
                    .fill(
                        isSelected
                            ? SkyPalette.accentBlue.opacity(0.16)
                            : (hoveredID == command.id ? Color.white.opacity(0.05) : .clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredID = hovering ? command.id : (hoveredID == command.id ? nil : hoveredID)
        }
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(SkyType.caption)
            .foregroundStyle(SkyPalette.chromeSecondaryText)
            .padding(.vertical, SkyMetrics.paddingTight)
    }

    private var hints: some View {
        HStack(spacing: SkyMetrics.clusterSpacing) {
            hint("↑↓", "move")
            hint("↵", "run")
            hint("esc", palette.isLocationMode ? "back" : "close")
            Spacer()
        }
    }

    private func hint(_ key: String, _ meaning: String) -> some View {
        HStack(spacing: SkyMetrics.paddingTight) {
            Text(key)
                .font(SkyType.footnoteNumeric)
                .foregroundStyle(SkyPalette.chromeText)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
            Text(meaning)
                .font(SkyType.footnote)
                .foregroundStyle(SkyPalette.chromeSecondaryText)
        }
    }

    private func runSelected() {
        guard let command = palette.selectedCommand else { return }
        viewModel.perform(command.action)
    }
}
