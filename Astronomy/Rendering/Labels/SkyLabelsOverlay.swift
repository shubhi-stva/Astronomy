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
                    .font(spec(for: label.style).font)
                    .tracking(spec(for: label.style).tracking)
                    .foregroundStyle(color(for: label.style))
                    // Replaces the single directional drop shadow. See
                    // `View.skyLabelHalo` for why a shadow with an offset is
                    // the wrong tool over a star field. The halo is scaled by
                    // the label's own opacity so a label fading out does not
                    // leave a dark smudge behind it after the text has gone.
                    .skyLabelHalo(strength: Double(label.opacity))
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

    /// The type spec for a label class. Sizes and weights are unchanged from
    /// the values that were tuned in place here; what moved is *where they
    /// live* (`SkyType`, alongside the chrome scale) and the addition of
    /// per-class tracking.
    ///
    /// Tracking is the substantive change. Constellation names now carry 1.4pt
    /// of letterspacing, which is the planetarium convention and does real
    /// work: a wide-tracked light face reads as a region of sky rather than as
    /// the name of a point in it, which is exactly the distinction between a
    /// constellation label and a star label. Star and deep-sky names get a
    /// fractional 0.2–0.3pt, which is not visible as spacing but stops the
    /// light weight from closing up at these sizes. Solar-system names get
    /// none: they are the one class set at full strength and normal fit.
    private func spec(for style: LabelStyle) -> TypeSpec {
        switch style {
        case .constellation: return SkyType.constellationLabelSpec
        // Star names are on screen permanently for the first-magnitude stars,
        // so they are set deliberately *lighter* than a planet's name: one
        // weight down and one size step down. They should read as a quiet
        // annotation on the star field, not as chrome competing with it.
        case .star: return SkyType.starLabelSpec
        case .solarSystem: return SkyType.solarSystemLabelSpec
        case .deepSky: return SkyType.deepSkyLabelSpec
        // Monospaced, because a satellite label is a designation rather than a
        // name and reads better set like one.
        case .satellite: return SkyType.satelliteLabelSpec
        // Wide-tracked small caps read as a compass bearing rather than as
        // the name of something in the sky.
        case .cardinal: return SkyType.cardinalLabelSpec
        }
    }

    /// Sky-label colours come from the dedicated `*LabelText` neutrals rather
    /// than from the chrome tints.
    ///
    /// The chrome tints are cool blues, which is right on a translucent panel
    /// and wrong on black: a faintly blue light grey over a deep navy field
    /// reads as *glowing*, and once you see it in a star name you cannot
    /// unsee it. The sky neutrals are the same muted family shifted a couple
    /// of percent — warm for the things that are point sources of light (stars,
    /// deep-sky objects, planets), cool for the things that are annotations on
    /// the sky rather than objects in it (constellations, compass bearings).
    ///
    /// The relative hierarchy is unchanged: solar-system brightest,
    /// constellations dimmest, everything between. The halo behind the text is
    /// what buys the legibility, so the colours did not need to get louder to
    /// get clearer — the whole point of doing it this way round.
    private func color(for style: LabelStyle) -> Color {
        switch style {
        case .constellation: return SkyPalette.constellationLabelText.opacity(0.82)
        case .star: return SkyPalette.starLabelText.opacity(0.86)
        case .solarSystem: return SkyPalette.solarSystemLabelText
        case .deepSky: return SkyPalette.starLabelText.opacity(0.92)
        case .satellite: return SkyPalette.satelliteLabel
        case .cardinal: return SkyPalette.cardinalLabelText.opacity(0.78)
        }
    }

    // The vertical nudge below the object's point now travels with the
    // candidate (`SkyLabelCandidate.verticalOffsetPoints`) and is baked into
    // `label.position` by `LabelLayoutEngine`, so collision testing sees the
    // same rectangle the user does. Constellations still use 0, stars 14, and
    // solar-system bodies scale theirs with their rendered disk.
}
