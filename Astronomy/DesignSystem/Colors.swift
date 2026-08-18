//
//  Colors.swift
//  Astronomy
//
//  Original visual identity for the app: deep navy/near-black sky, cool
//  whites and muted blues for chrome, warm tones reserved for stars and
//  celestial bodies. Deliberately distinct from any existing sky-mapping
//  app's palette or layout.
//

import SwiftUI

enum SkyPalette {
    static let voidBackground = Color(red: 0.02, green: 0.03, blue: 0.07)
    static let horizonHaze = Color(red: 0.05, green: 0.08, blue: 0.14)

    static let chromeText = Color(red: 0.90, green: 0.93, blue: 0.98)
    static let chromeSecondaryText = Color(red: 0.62, green: 0.68, blue: 0.78)
    static let accentBlue = Color(red: 0.42, green: 0.62, blue: 0.98)

    static let panelStroke = Color.white.opacity(0.08)

    /// Satellite labels. Matches the cool cyan cast of the satellite marker in
    /// `StarAppearance`, kept quiet enough that a dozen of them on screen never
    /// competes with a star name.
    static let satelliteLabel = Color(red: 0.62, green: 0.86, blue: 0.92).opacity(0.88)
}

/// A minimal floating translucent "glass" panel used for the info panel,
/// search field, time bar, and location control.
struct GlassPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(SkyPalette.horizonHaze.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(SkyPalette.panelStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
    }
}
