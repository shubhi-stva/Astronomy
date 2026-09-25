//
//  SearchBarView.swift
//  Astronomy
//
//  Compact floating search pill: collapsed to a single icon so it stays out
//  of the sky, expanding to a field (and result list) on click/focus.
//  Matches stars (by proper name or any catalogue designation), planets and
//  dwarf planets, deep-sky objects, satellites and constellations; choosing a
//  result recenters the camera on it.
//

import SwiftUI

struct SearchBarView: View {
    @Bindable var viewModel: SkyViewModel

    @FocusState private var isFocused: Bool
    @State private var isExpanded = false

    private var showsField: Bool { isExpanded || isFocused || !viewModel.searchText.isEmpty }

    /// One glyph per category, so the eye can sort the result list before
    /// reading any of it.
    private static func symbol(for kind: CelestialObjectKind) -> String {
        switch kind {
        case .star: return "sparkle"
        case .sun: return "sun.max"
        case .moon: return "moon"
        case .planet: return "circle.circle"
        case .dwarfPlanet: return "circle.dotted"
        case .deepSky: return "hurricane"
        case .satellite: return "antenna.radiowaves.left.and.right"
        case .constellation: return "point.topleft.down.to.point.bottomright.curvepath"
        case .planetMoon: return "circle.dotted.circle"
        }
    }

    private static func categoryLabel(for object: CelestialObject) -> String {
        switch object.kind {
        case .star: return "Star"
        case .sun: return "Sun"
        case .moon: return "Moon"
        case .planet: return "Planet"
        case .dwarfPlanet: return "Dwarf planet"
        // The morphological class is more use than the word "deepSky": a
        // result reading "Galaxy" or "Open Cluster" says what it is.
        case .deepSky: return object.deepSkyType?.displayName ?? "Deep-sky"
        case .satellite: return "Satellite"
        case .constellation: return "Constellation"
        case .planetMoon: return "Moon of Jupiter"
        }
    }

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: SkyMetrics.paddingSnug) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(showsField ? SkyPalette.accentBlue : SkyPalette.chromeSecondaryText)
                        .onTapGesture {
                            isExpanded = true
                            isFocused = true
                        }

                    if showsField {
                        TextField("Search the sky", text: $viewModel.searchText)
                            .textFieldStyle(.plain)
                            .focused($isFocused)
                            // Numeric-capable body: people type catalogue
                            // designations here ("M42", "NGC 7000", "25544"),
                            // and the field should not re-flow as they do.
                            .font(SkyType.bodyNumeric)
                            .foregroundStyle(SkyPalette.chromeText)
                            .onChange(of: viewModel.searchText) { _, _ in
                                viewModel.updateSearchResults()
                            }
                            .onSubmit {
                                if let first = viewModel.searchResults.first {
                                    viewModel.focus(on: first)
                                }
                            }

                        if !viewModel.searchText.isEmpty {
                            Button {
                                viewModel.searchText = ""
                                viewModel.searchResults = []
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(SkyPalette.chromeSecondaryText)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if showsField && !viewModel.searchResults.isEmpty {
                    Divider()
                        .overlay(SkyPalette.panelStroke)
                        .padding(.vertical, SkyMetrics.paddingSnug)

                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.searchResults.prefix(8)) { object in
                            Button {
                                viewModel.focus(on: object)
                                isExpanded = false
                                isFocused = false
                            } label: {
                                HStack(spacing: SkyMetrics.paddingSnug) {
                                    // A category icon *and* a word. With
                                    // stars, deep-sky objects, satellites and
                                    // constellations all in one list, "M42"
                                    // and "ISS" and "Ori" are otherwise three
                                    // indistinguishable rows of text.
                                    Image(systemName: Self.symbol(for: object.kind))
                                        .font(SkyType.caption)
                                        .frame(width: 14)
                                        .foregroundStyle(SkyPalette.accentBlue.opacity(0.85))
                                    // Monospaced-digit: a result list mixing
                                    // "Betelgeuse", "M42" and "NGC 7000" has a
                                    // digit in most rows, and proportional
                                    // figures make the list look ragged.
                                    Text(object.name)
                                        .font(SkyType.bodyNumeric)
                                        .foregroundStyle(SkyPalette.chromeText)
                                        .lineLimit(1)
                                    Spacer(minLength: SkyMetrics.paddingSnug)
                                    // The category is a tag on the row, set in
                                    // the same tracked caps as every other tag
                                    // in the app so the eye learns one form.
                                    Text(Self.categoryLabel(for: object).uppercased())
                                        .font(SkyType.sectionLabel)
                                        .tracking(SkyType.sectionLabelSpec.tracking)
                                        .foregroundStyle(SkyPalette.chromeSecondaryText.opacity(0.85))
                                        .lineLimit(1)
                                }
                                .padding(.vertical, SkyMetrics.paddingTight)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(width: showsField ? 300 : 16)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isExpanded = true
            isFocused = true
        }
        .animation(.easeInOut(duration: 0.22), value: showsField)
        .onChange(of: isFocused) { _, focused in
            if !focused && viewModel.searchText.isEmpty {
                isExpanded = false
            }
        }
    }
}
