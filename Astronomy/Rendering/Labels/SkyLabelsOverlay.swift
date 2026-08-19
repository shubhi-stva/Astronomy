//
//  SkyLabelsOverlay.swift
//  Astronomy
//
//  The bounded set of SwiftUI Text labels for constellations, bright/named
//  stars, and the Sun/Moon/planets. Positions come pre-laid-out (collision
//  resolved, faded) from `LabelLayoutEngine` via `SkyRenderer.labelSink`; this
//  view only draws them, animating opacity changes for a smooth fade rather
//  than a hard pop-in/out.
//

import SwiftUI

struct SkyLabelsOverlay: View {
    let labels: [SkyLabel]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(labels) { label in
                Text(label.text)
                    .font(font(for: label.style))
                    .tracking(label.style == .cardinal ? 1.6 : 0)
                    .foregroundStyle(color(for: label.style))
                    .shadow(color: .black.opacity(0.6), radius: 3)
                    .fixedSize()
                    // NOTHING here is animated by SwiftUI, deliberately. The
                    // view is a pure function of the frame it was handed, so a
                    // label is always exactly where this frame says it is.
                    //
                    // The fade is not lost — it moved into `LabelLayoutEngine`,
                    // which ramps each label's opacity over time and hands the
                    // ramped value down. That is the only way to keep it: a
                    // label's opacity varies continuously as it moves (terrain
                    // dimming depends on position), so an implicit animation
                    // keyed on opacity was permanently in flight, and an
                    // in-flight animation carries the position change with it.
                    // That is what made labels trail the sky while panning.
                    .opacity(label.opacity)
                    .position(x: label.position.x, y: label.position.y)
            }
        }
    }

    private func font(for style: LabelStyle) -> Font {
        switch style {
        case .constellation: return .system(size: 12, weight: .light, design: .rounded)
        // Star names are now on screen permanently for the first-magnitude
        // stars, so they are set deliberately *lighter* than a planet's name:
        // one weight down and one size step down. They should read as a quiet
        // annotation on the star field, not as chrome competing with it.
        case .star: return .system(size: 10.5, weight: .light)
        case .solarSystem: return .system(size: 12, weight: .medium)
        case .deepSky: return .system(size: 11, weight: .regular, design: .rounded)
        // Monospaced, because a satellite label is a designation rather than a
        // name and reads better set like one.
        case .satellite: return .system(size: 10, weight: .regular, design: .monospaced)
        // Wide-tracked small caps read as a compass bearing rather than as
        // the name of something in the sky.
        case .cardinal: return .system(size: 11, weight: .semibold, design: .rounded)
        }
    }

    private func color(for style: LabelStyle) -> Color {
        switch style {
        case .constellation: return SkyPalette.chromeSecondaryText.opacity(0.85)
        // Lower contrast than `.solarSystem` as well as lighter: the secondary
        // chrome tint at 82% against the planets' full-strength primary. Still
        // comfortably legible over the sky, which is very dark.
        case .star: return SkyPalette.chromeSecondaryText.opacity(0.82)
        case .solarSystem: return SkyPalette.chromeText
        case .deepSky: return SkyPalette.chromeSecondaryText.opacity(0.95)
        case .satellite: return SkyPalette.satelliteLabel
        case .cardinal: return SkyPalette.chromeText.opacity(0.75)
        }
    }

    // The vertical nudge below the object's point now travels with the
    // candidate (`SkyLabelCandidate.verticalOffsetPoints`) and is baked into
    // `label.position` by `LabelLayoutEngine`, so collision testing sees the
    // same rectangle the user does. Constellations still use 0, stars 14, and
    // solar-system bodies scale theirs with their rendered disk.
}
