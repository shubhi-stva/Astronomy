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
                    .position(x: label.position.x, y: label.position.y + offset(for: label.style))
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

    /// Nudges the label just below its object's point, more so for
    /// constellation names (which sit at a figure centroid, not a point).
    private func offset(for style: LabelStyle) -> CGFloat {
        switch style {
        case .constellation: return 0
        case .star, .solarSystem: return 14
        }
    }
}
