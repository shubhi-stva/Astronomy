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
                        if viewModel.handleMeasureClick(on: object) { return }
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

                // Everything that is not the sky itself, tinted as one.
                //
                // The tint is applied here, at the root of the chrome, and
                // nowhere else. Applying it per view would mean every control
                // added later had to remember; applying it over the whole
                // window would mean re-tinting the Metal view through a SwiftUI
                // filter, which is both slower and wrong — the sky gets the
                // same transform in its own fragment shaders, where the star
                // brightness hierarchy can be preserved exactly.
                chromeLayer
                    .nightVision(strength: viewModel.nightVision.isEnabled ? 1 : 0)
                    .animation(
                        .easeInOut(duration: NightVision.transitionDuration),
                        value: viewModel.nightVision.isEnabled
                    )
            }
        }
        .preferredColorScheme(.dark)
        .background(SkyPalette.voidBackground)
        .background(
            KeyCommandMonitor { command in
                switch command {
                case .toggleNightVision:
                    withAnimation(.easeInOut(duration: NightVision.transitionDuration)) {
                        viewModel.nightVision.toggle()
                    }
                    return true
                case .measure:
                    // A second press clears, so the same key both arms and
                    // cancels rather than needing the palette to undo it.
                    if viewModel.measureAnchor == nil {
                        viewModel.beginMeasure()
                    } else {
                        viewModel.clearMeasure()
                    }
                    return true
                case .toggleGrid:
                    viewModel.equatorialGridEnabled.toggle()
                    return true
                case .togglePasses:
                    viewModel.isPassesPanelPresented.toggle()
                    return true
                case .openCommandPalette:
                    viewModel.presentPalette()
                    return true
                case .dismiss:
                    // Only claimed when the palette is open. Esc has to keep
                    // working for everything else — closing a text field's
                    // editing session, for instance — the rest of the time.
                    guard viewModel.palette.isPresented else { return false }
                    viewModel.palette.escape()
                    return true
                }
            }
        )
    }

    @ViewBuilder
    private var chromeLayer: some View {
        ZStack {
            SkyLabelsLayer(viewModel: viewModel)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                    // One gap between the top controls and one inset from the
                    // window edge, both from `SkyMetrics`, so the two right-hand
                    // pills sit in the same rhythm as everything inside them.
                    HStack(alignment: .top, spacing: SkyMetrics.paddingSnug) {
                        SearchBarView(viewModel: viewModel)

                        Spacer()

                        CalendarToggleView(viewModel: viewModel)

                        TonightToggleView(viewModel: viewModel)

                        PassesToggleView(viewModel: viewModel)

                        NightVisionToggleView(controller: viewModel.nightVision)

                        SatelliteControlView(viewModel: viewModel)

                        LocationControlView(viewModel: viewModel, isExpanded: $showLocationControl)
                    }
                    .padding(SkyMetrics.paddingScreen)

                    Spacer()

                    if let selected = viewModel.selectedObject {
                        InfoPanelView(
                            object: selected,
                            onDismiss: { viewModel.selectedObject = nil },
                            facts: viewModel.selectedObjectFacts,
                            timeZone: viewModel.location.timeZone,
                            constellationNames: InfoPanelView.constellationNames,
                            pathRange: viewModel.pathRange,
                            onSelectPathRange: { viewModel.togglePath(range: $0) },
                            pathTruncated: viewModel.skyPath?.truncatedForAccuracy ?? false
                        )
                        .padding(.bottom, SkyMetrics.paddingSnug)
                    }

                    TimeBarView(viewModel: viewModel)
                        .padding(.bottom, SkyMetrics.rowSpacing)

                    // Required attribution. The Milky Way panorama is ESO's
                    // under CC BY 4.0, which obliges the credit to be shown
                    // "in a clear and readable manner to all users" — a note
                    // in DATA_SOURCES.md does not satisfy that, since users
                    // never see the repository. Kept deliberately quiet so it
                    // does not compete with the sky.
                    Text("Milky Way: ESO/S. Brunier (CC BY 4.0) · Catalogues: HYG, OpenNGC (CC BY-SA 4.0) · Satellite elements: CelesTrak")
                        .font(SkyType.footnote)
                        .foregroundStyle(SkyPalette.chromeSecondaryText.opacity(0.5))
                        .padding(.bottom, SkyMetrics.paddingSnug)
                }

                // The dashboards hang under the pills that open them, on the
                // right, so the middle of the sky stays clear. Side by side
                // when both are open, rather than stacked: two panels down the
                // right edge would run off the bottom of a small window.
                if viewModel.isTonightPanelPresented || viewModel.isCalendarPresented
                    || viewModel.isPassesPanelPresented {
                    VStack {
                        HStack(alignment: .top, spacing: SkyMetrics.paddingSnug) {
                            Spacer()
                            if viewModel.isPassesPanelPresented {
                                PassesPanelView(viewModel: viewModel)
                            }
                            if viewModel.isCalendarPresented {
                                CalendarPanelView(viewModel: viewModel)
                            }
                            if viewModel.isTonightPanelPresented {
                                TonightPanelView(viewModel: viewModel)
                            }
                        }
                        Spacer()
                    }
                    .padding(SkyMetrics.paddingScreen)
                    .padding(.top, 44)
                    .transition(.opacity)
                }

                // Always present; it decides for itself whether it is on
                // screen, which keeps the palette's per-keystroke state out of
                // every body above this one. See `CommandPaletteModel`.
                CommandPaletteOverlay(viewModel: viewModel)

                if viewModel.isLoadingCatalog {
                    VStack(spacing: SkyMetrics.paddingSnug) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(SkyPalette.chromeText)
                        Text("Loading star catalog…")
                            .font(SkyType.caption)
                            .foregroundStyle(SkyPalette.chromeSecondaryText)
                    }
                }
        }
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
