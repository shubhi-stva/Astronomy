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

                SkyLabelsLayer(viewModel: viewModel)
                    .allowsHitTesting(false)

                VStack {
                    HStack(alignment: .top) {
                        SearchBarView(viewModel: viewModel)

                        Spacer()

                        SatelliteControlView(viewModel: viewModel)

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
                        .padding(.bottom, 6)

                    // Required attribution. The Milky Way panorama is ESO's
                    // under CC BY 4.0, which obliges the credit to be shown
                    // "in a clear and readable manner to all users" — a note
                    // in DATA_SOURCES.md does not satisfy that, since users
                    // never see the repository. Kept deliberately quiet so it
                    // does not compete with the sky.
                    Text("Milky Way: ESO/S. Brunier (CC BY 4.0) · Catalogues: HYG, OpenNGC (CC BY-SA 4.0) · Satellite elements: CelesTrak")
                        .font(.system(size: 9))
                        .foregroundStyle(SkyPalette.chromeSecondaryText.opacity(0.55))
                        .padding(.bottom, 10)
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

/// Isolates the label overlay's dependency on `viewModel.labels`.
///
/// This exists for one reason, and it is a performance reason rather than a
/// structural one. `labels` is republished every frame — up to 120 times a
/// second — and with `@Observable` a view body depends on exactly the
/// properties it *reads*. Reading `viewModel.labels` directly in `SkyView`'s
/// body therefore made the entire screen depend on it: every label update
/// invalidated and re-evaluated the Metal representable (running
/// `updateNSView`), the search bar, the location and satellite controls, the
/// time bar and the info panel. SwiftUI cannot sustain rebuilding all of that
/// at display rate, so it coalesced the updates and the labels visibly lagged
/// the sky by a fraction of a second while panning.
///
/// Reading `labels` down here confines the invalidation to this one small view.
/// Nothing else on screen re-evaluates when a label moves.
private struct SkyLabelsLayer: View {
    let viewModel: SkyViewModel

    var body: some View {
        SkyLabelsOverlay(labels: viewModel.labels)
    }
}

#Preview {
    SkyView()
}
