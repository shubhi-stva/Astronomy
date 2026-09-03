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

    /// Reserved for one job: telling the user the sky on screen is not the sky
    /// outside. Used by the time bar when simulated time has left real time and
    /// by the accuracy caveats that go with it. Warm enough to read as a
    /// caution against the cool chrome without shouting.
    static let warningAmber = Color(red: 0.96, green: 0.74, blue: 0.38)

    /// Satellite labels. Matches the cool cyan cast of the satellite marker in
    /// `StarAppearance`, kept quiet enough that a dozen of them on screen never
    /// competes with a star name.
    static let satelliteLabel = Color(red: 0.62, green: 0.86, blue: 0.92).opacity(0.88)

    // MARK: - Sky label neutrals
    //
    // Labels drawn *on the sky* rather than on glass. They are deliberately not
    // the chrome tints: chrome sits on a translucent panel that already
    // separates it from the background, whereas a sky label has nothing behind
    // it but stars, so it needs its own, very slightly warmer neutrals to stop
    // the cool chrome blue reading as a faint blue glow against a black field.
    //
    // "Warmer" here means a couple of percent, not a colour cast. The palette
    // stays muted; these are the same family, nudged.

    /// Named stars and deep-sky objects: a hair warm of neutral so the text
    /// sits in the same family as the star glyphs beside it.
    static let starLabelText = Color(red: 0.86, green: 0.86, blue: 0.83)
    /// Constellation names: cooler and dimmer than a star name, because a
    /// constellation is a region rather than a thing and should recede.
    static let constellationLabelText = Color(red: 0.70, green: 0.75, blue: 0.83)
    /// Sun, Moon, planets — the only sky labels at full strength.
    static let solarSystemLabelText = Color(red: 0.95, green: 0.94, blue: 0.90)
    /// Compass bearings on the horizon. Chrome, not sky, so cool and quiet.
    static let cardinalLabelText = Color(red: 0.72, green: 0.78, blue: 0.86)

    /// The colour of the soft dark halo laid behind every sky label.
    ///
    /// Not pure black: the sky is a deep navy, and a pure-black halo over it
    /// reads as a visible rectangle of dark around the text once you notice it.
    /// Matching the void tone means the halo disappears into the background and
    /// only its effect — the separation — is visible. See
    /// `View.skyLabelHalo(strength:)`.
    static let labelHalo = Color(red: 0.01, green: 0.02, blue: 0.05)
}

// MARK: - Sky label legibility

extension View {
    /// A soft dark halo for text drawn directly on the sky.
    ///
    /// A single drop shadow is the obvious thing and it is wrong here, because
    /// a drop shadow is directional: it separates the text from the background
    /// on two sides and leaves the other two touching. Over a star field the
    /// unshadowed side is exactly where a star lands behind a letterform and
    /// the letter dissolves.
    ///
    /// Three concentric zero-offset shadows approximate an omnidirectional
    /// halo instead: a tight, fairly opaque one that thickens the letter's
    /// edge, a mid one that does the actual separating, and a wide, very faint
    /// one that keeps the transition from having a visible boundary. The total
    /// darkness is *lower* than the single 0.6-opacity shadow this replaced —
    /// the point is legibility, not weight, and the user has consistently
    /// rejected anything that reads as heavier chrome.
    ///
    /// Cost: SwiftUI shadows on `Text` are GPU-side; this is three small blurs
    /// on a bounded set of short strings (the layout engine caps how many
    /// labels exist), so it does not add per-frame CPU work.
    func skyLabelHalo(strength: Double = 1.0) -> some View {
        self
            .shadow(color: SkyPalette.labelHalo.opacity(0.55 * strength), radius: 1)
            .shadow(color: SkyPalette.labelHalo.opacity(0.40 * strength), radius: 2.5)
            .shadow(color: SkyPalette.labelHalo.opacity(0.22 * strength), radius: 6)
    }
}

/// A minimal floating translucent "glass" panel used for the info panel,
/// search field, time bar, satellite control and location control.
///
/// This is the *only* chrome treatment in the app, and that is the point. Every
/// floating control is one of these: one corner radius (`SkyMetrics.radiusPanel`),
/// one inset (`paddingPanel`), one material, one hairline, one shadow. When the
/// five of them are on screen together — which is the normal case — they have
/// to read as one system rather than as five widgets that happen to be
/// translucent.
///
/// The stack, outside in: a hairline stroke, the system `.ultraThinMaterial`,
/// and beneath it a wash of the horizon tint. The tint is load-bearing. The
/// material alone samples whatever is behind it, and over a bright stretch of
/// Milky Way that turns the panel pale grey; the wash keeps it reading as night
/// sky. It is kept at 30% so the panel is still obviously translucent — the sky
/// dominates, and a control you cannot see through has stopped being an overlay.
extension View {
    /// `GlassPanel`'s treatment without its padding, for controls that own
    /// their own insets — the toggle pills in the top-right cluster.
    ///
    /// This exists so those pills cannot drift from the panels. Each of them
    /// previously spelled the same four-layer stack out by hand, which is three
    /// copies of a decision that has to stay identical for the chrome to read
    /// as one system.
    func chromePill() -> some View {
        let shape = RoundedRectangle(cornerRadius: SkyMetrics.radiusPanel, style: .continuous)
        return self
            .background(shape.fill(.ultraThinMaterial))
            .background(shape.fill(SkyPalette.horizonHaze.opacity(SkyMetrics.panelTintOpacity)))
            .overlay(shape.strokeBorder(SkyPalette.panelStroke, lineWidth: SkyMetrics.strokeWidth))
    }
}

struct GlassPanel<Content: View>: View {
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SkyMetrics.radiusPanel, style: .continuous)
    }

    var body: some View {
        content
            .padding(SkyMetrics.paddingPanel)
            .background(shape.fill(.ultraThinMaterial))
            .background(shape.fill(SkyPalette.horizonHaze.opacity(SkyMetrics.panelTintOpacity)))
            .overlay(shape.strokeBorder(SkyPalette.panelStroke, lineWidth: SkyMetrics.strokeWidth))
            // Softer and tighter than it was. A large, dark shadow under a
            // small pill reads as weight, and the brief is that these are
            // lightweight overlays on a sky, not floating cards.
            .shadow(
                color: .black.opacity(SkyMetrics.shadowOpacity),
                radius: SkyMetrics.shadowRadius,
                y: SkyMetrics.shadowYOffset
            )
    }
}
