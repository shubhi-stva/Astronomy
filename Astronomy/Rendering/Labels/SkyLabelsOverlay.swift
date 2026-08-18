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
                    // Opacity is the *only* animated property. It is applied —
                    // and its animation scoped — beneath `.position`, so the
                    // fade cannot leak into the placement below.
                    .opacity(label.opacity)
                    .animation(.easeInOut(duration: 0.28), value: label.opacity)
                    // Position is set outside that scope and must never be
                    // animated: the label has to sit on its object in the same
                    // frame the object moves. Anything easing here reads as the
                    // labels sliding along behind the sky while you pan.
                    .position(x: label.position.x, y: label.position.y)
            }
        }
    }

    private func font(for style: LabelStyle) -> Font {
        switch style {
        case .constellation: return .system(size: 12, weight: .light, design: .rounded)
        case .star: return .system(size: 11, weight: .regular)
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
        case .star: return SkyPalette.chromeText.opacity(0.9)
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
