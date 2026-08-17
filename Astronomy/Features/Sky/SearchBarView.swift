//
//  SearchBarView.swift
//  Astronomy
//
//  Compact floating search pill: collapsed to a single icon so it stays out
//  of the sky, expanding to a field (and result list) on click/focus.
//  Substring match against loaded stars + planets; choosing a result
//  recenters the camera on it.
//

import SwiftUI

struct SearchBarView: View {
    @Bindable var viewModel: SkyViewModel

    @FocusState private var isFocused: Bool
    @State private var isExpanded = false

    private var showsField: Bool { isExpanded || isFocused || !viewModel.searchText.isEmpty }

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(showsField ? SkyPalette.accentBlue : SkyPalette.chromeSecondaryText)
                        .onTapGesture {
                            isExpanded = true
                            isFocused = true
                        }

                    if showsField {
                        TextField("Search stars & planets", text: $viewModel.searchText)
                            .textFieldStyle(.plain)
                            .focused($isFocused)
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
                                    .foregroundStyle(SkyPalette.chromeSecondaryText)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if showsField && !viewModel.searchResults.isEmpty {
                    Divider()
                        .overlay(SkyPalette.panelStroke)
                        .padding(.vertical, 8)

                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.searchResults.prefix(8)) { object in
                            Button {
                                viewModel.focus(on: object)
                                isExpanded = false
                                isFocused = false
                            } label: {
                                HStack {
                                    Text(object.name)
                                        .foregroundStyle(SkyPalette.chromeText)
                                    Spacer()
                                    Text(object.kind.rawValue.capitalized)
                                        .font(.caption2)
                                        .foregroundStyle(SkyPalette.chromeSecondaryText)
                                }
                                .padding(.vertical, 4)
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
