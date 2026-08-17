//
//  SkyView.swift
//  Astronomy
//
//  Root fullscreen sky view: fills the window with the Metal-rendered sky
//  and overlays minimal floating translucent panels (search, info, time,
//  location) — no chrome, no navigation split view, no template UI.
//

import SwiftUI

struct SkyView: View {
    @State private var viewModel = SkyViewModel()
    @State private var showLocationControl = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                SkyPalette.voidBackground.ignoresSafeArea()

                SkyMetalView(
                    frameDataProvider: { viewModel.currentFrameData() },
                    onDrag: { dx, dy, size in
                        viewModel.camera.applyDrag(deltaX: dx, deltaY: dy, viewportSize: size)
                    },
                    onPanEnded: { vx, vy, size in
                        viewModel.handlePanEnded(velocityX: vx, velocityY: vy, viewportSize: size)
                    },
                    onZoom: { delta in
                        viewModel.camera.applyZoom(delta: delta)
                    },
                    onZoomFactor: { factor in
                        viewModel.handleZoomFactor(factor)
                    },
                    onSelect: { object in
                        viewModel.selectedObject = object
                    },
                    onFocus: { object in
                        viewModel.flyToFocus(on: object)
                    },
                    onLabels: { labels in
                        viewModel.labels = labels
                    }
                )
                .ignoresSafeArea()
                .onAppear { viewModel.viewportSize = proxy.size }
                .onChange(of: proxy.size) { _, newSize in
                    viewModel.viewportSize = newSize
                }

                SkyLabelsOverlay(labels: viewModel.labels)
                    .allowsHitTesting(false)

                VStack {
                    HStack(alignment: .top) {
                        SearchBarView(viewModel: viewModel)

                        Spacer()

                        LocationControlView(viewModel: viewModel, isExpanded: $showLocationControl)
                    }
                    .padding(20)

                    Spacer()

                    if let selected = viewModel.selectedObject {
                        InfoPanelView(object: selected) {
                            viewModel.selectedObject = nil
                        }
                        .padding(.bottom, 8)
                    }

                    TimeBarView(viewModel: viewModel)
                        .padding(.bottom, 20)
                }

                if viewModel.isLoadingCatalog {
                    VStack(spacing: 8) {
                        ProgressView()
                            .tint(SkyPalette.chromeText)
                        Text("Loading star catalog…")
                            .font(.caption)
                            .foregroundStyle(SkyPalette.chromeSecondaryText)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .background(SkyPalette.voidBackground)
    }
}

#Preview {
    SkyView()
}
