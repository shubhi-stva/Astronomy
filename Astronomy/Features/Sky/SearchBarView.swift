//
//  SearchBarView.swift
//  Astronomy
//
//  Minimal search field: substring match against loaded stars + planets,
//  recenters the camera on the chosen result.
//

import SwiftUI

struct SearchBarView: View {
    @Bindable var viewModel: SkyViewModel

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(SkyPalette.chromeSecondaryText)
                    TextField("Search stars & planets", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                        .foregroundStyle(SkyPalette.chromeText)
                        .onChange(of: viewModel.searchText) { _, _ in
                            viewModel.updateSearchResults()
                        }
                }

                if !viewModel.searchResults.isEmpty {
                    Divider()
                        .overlay(SkyPalette.panelStroke)
                        .padding(.vertical, 8)

                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.searchResults.prefix(8)) { object in
                            Button {
                                viewModel.focus(on: object)
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
        }
    }
}
