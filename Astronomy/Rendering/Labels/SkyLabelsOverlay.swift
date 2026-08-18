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
                    .foregroundStyle(color(for: label.style))
                    .shadow(color: .black.opacity(0.6), radius: 3)
                    .fixedSize()
                    .position(x: label.position.x, y: label.position.y)
                    .opacity(label.opacity)
                    .animation(.easeInOut(duration: 0.35), value: label.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: labels)
    }

    private func font(for style: LabelStyle) -> Font {
        switch style {
        case .constellation: return .system(size: 12, weight: .light, design: .rounded)
        case .star: return .system(size: 11, weight: .regular)
        case .solarSystem: return .system(size: 12, weight: .medium)
        }
    }

    private func color(for style: LabelStyle) -> Color {
        switch style {
        case .constellation: return SkyPalette.chromeSecondaryText.opacity(0.85)
        case .star: return SkyPalette.chromeText.opacity(0.9)
        case .solarSystem: return SkyPalette.chromeText
        }
    }

    // The vertical nudge below the object's point now travels with the
    // candidate (`SkyLabelCandidate.verticalOffsetPoints`) and is baked into
    // `label.position` by `LabelLayoutEngine`, so collision testing sees the
    // same rectangle the user does. Constellations still use 0, stars 14, and
    // solar-system bodies scale theirs with their rendered disk.
}
