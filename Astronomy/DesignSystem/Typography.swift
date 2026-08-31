//
//  Typography.swift
//  Astronomy
//
//  One type scale and one chrome-metric scale for the whole app.
//
//  Why this file exists at all: the floating controls grew one at a time, and
//  each one reached for `.font(.system(size: 9))` or `.caption2` in isolation.
//  The result was six sizes that were nearly-but-not-quite the same, weights
//  chosen per-view, and numbers set in proportional digits so the clock and the
//  satellite count visibly twitched as digits changed width. None of that is
//  visible in any single view; all of it is visible when four panels are on
//  screen at once, which is the normal case here.
//
//  Three rules the scale encodes:
//
//   1. **Every changing number is monospaced-digit.** The clock, the playback
//      rate, RA/Dec, altitude/azimuth, magnitudes, satellite counts, latitude
//      and longitude. A readout that re-flows while you watch it reads as
//      unstable, and this app's whole claim is that its numbers are trustworthy.
//   2. **Small text gets tracking, not just a smaller size.** Below about
//      10.5pt, letterfit is what carries legibility, and the wide-tracked small
//      label is the planetarium idiom for a category or a bearing.
//   3. **Nothing is set below 9pt.** That is the legibility floor over a live,
//      moving, dark background; it is asserted in `TypographyTests`.
//
//  Everything is built on Apple's system faces (SF Pro / SF Pro Rounded / SF
//  Mono via `.monospaced`). No bundled typeface, no third-party face. On macOS
//  the system face is also the correct choice: it is what every other numeric
//  readout the user sees is set in, and it has the optical sizes and the
//  monospaced-digit variant this scale depends on.
//

import SwiftUI

/// A value-level description of one entry in the type scale.
///
/// The `Font` is what the views use; this struct is what makes the scale
/// *testable*. `Font` is opaque — you cannot ask it its size, its weight, or
/// whether it uses monospaced digits — so the facts we actually want to hold
/// the scale to (monotonic sizes, digits are monospaced, nothing below the
/// legibility floor) have to live somewhere inspectable. They live here, and
/// `font` is derived from them so the two cannot drift apart.
struct TypeSpec: Sendable, Equatable {
    /// Point size. Fractional sizes are deliberate in a couple of places: the
    /// gap between a star name and a planet name wants to be smaller than a
    /// whole point.
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    /// True when this style is ever used to set digits that change while the
    /// user is looking at them.
    let monospacedDigit: Bool
    /// Letterspacing in points, applied by the caller via `.tracking(_:)`.
    /// Non-zero only for the small, quiet, quasi-small-caps labels.
    let tracking: CGFloat

    init(
        size: CGFloat,
        weight: Font.Weight,
        design: Font.Design = .default,
        monospacedDigit: Bool = false,
        tracking: CGFloat = 0
    ) {
        self.size = size
        self.weight = weight
        self.design = design
        self.monospacedDigit = monospacedDigit
        self.tracking = tracking
    }

    /// The SwiftUI font. Computed from the spec, but every call site uses one
    /// of the `static let` constants below, so this runs a handful of times at
    /// process start and never again — in particular never per frame.
    var font: Font {
        let base = Font.system(size: size, weight: weight, design: design)
        return monospacedDigit ? base.monospacedDigit() : base
    }
}

/// The app's type scale.
///
/// Named by *role*, not by size, so a view says what a piece of text is rather
/// than how big it happens to be. Sizes come from a five-step ramp —
/// 9 / 10.5 / 11 / 12 / 15 — which is tight on purpose: this is chrome around a
/// sky, and a chrome hierarchy with more than a handful of levels is a chrome
/// hierarchy that has started competing with its content.
enum SkyType {

    // MARK: - Specs (the testable model)

    /// The one heading in the app: the selected object's name in the info
    /// panel. Semibold rather than bold — bold at 15pt over glass is heavier
    /// than anything else on screen and pulls the eye off the sky.
    static let panelTitleSpec = TypeSpec(size: 15, weight: .semibold)

    /// The quiet category line under a title ("Planet", "Open Cluster") and
    /// the field labels in the location form. Wide-tracked because at 9pt the
    /// tracking is doing more work for legibility than the size is.
    static let sectionLabelSpec = TypeSpec(size: 9, weight: .semibold, tracking: 0.7)

    /// Default panel body text: search results, control names.
    static let bodySpec = TypeSpec(size: 12, weight: .regular)

    /// Body text that contains a number the user might read off precisely
    /// (a coordinate string, a place's latitude/longitude).
    static let bodyNumericSpec = TypeSpec(size: 12, weight: .regular, monospacedDigit: true)

    /// The row labels in the info panel ("Right Ascension", "Altitude").
    static let captionSpec = TypeSpec(size: 11, weight: .regular)

    /// The values beside those labels, and every other small readout.
    static let captionNumericSpec = TypeSpec(size: 11, weight: .medium, monospacedDigit: true)

    /// Explanatory small print: accuracy caveats, the element-set staleness
    /// note, the data attribution line. The floor of the scale.
    static let footnoteSpec = TypeSpec(size: 9, weight: .regular)

    /// Footnotes that quote a number ("Elements 7.7 days old", the visible /
    /// tracked satellite count).
    static let footnoteNumericSpec = TypeSpec(size: 9, weight: .regular, monospacedDigit: true)

    /// The clock. The largest numeric readout in the app and the one that
    /// changes most often, so monospaced digits matter here more than anywhere.
    static let clockSpec = TypeSpec(size: 12.5, weight: .medium, monospacedDigit: true)

    /// The playback-rate readout and other short numeric chips inside controls.
    static let readoutSpec = TypeSpec(size: 11, weight: .medium, monospacedDigit: true)

    /// Small state badges set in caps: "OFF REAL TIME". Heavy tracking is what
    /// makes an all-caps run of nine characters readable at 9pt.
    static let badgeSpec = TypeSpec(size: 9, weight: .semibold, tracking: 0.9)

    /// The soft controls — button captions inside the pills. `.rounded` here
    /// and nowhere else: it suits a tappable affordance and reads as friendly,
    /// but a whole app set in Rounded reads as a toy, and this one is trying to
    /// be believed about arcseconds.
    static let controlSpec = TypeSpec(size: 12, weight: .medium, design: .rounded)

    // MARK: - Sky labels
    //
    // These sit over the sky itself, not over glass, so they are tuned
    // separately: lighter weights (a glowing dark background makes text look
    // heavier than it is) and tracking on the classes that read as annotation
    // rather than as a name.

    /// Constellation names. Light, wide-tracked, near-small-caps in feel — the
    /// planetarium convention, and it makes a constellation name read as a
    /// region of sky rather than as an object in it.
    static let constellationLabelSpec = TypeSpec(size: 12, weight: .light, design: .rounded, tracking: 1.4)
    /// Named stars: one step down and one weight lighter than a planet, since
    /// first-magnitude star names are on screen permanently.
    static let starLabelSpec = TypeSpec(size: 10.5, weight: .light, tracking: 0.3)
    /// Sun, Moon and planets — the only sky labels set at full strength.
    static let solarSystemLabelSpec = TypeSpec(size: 12, weight: .medium)
    static let deepSkyLabelSpec = TypeSpec(size: 11, weight: .regular, design: .rounded, tracking: 0.2)
    /// Satellite designations, set monospaced because that is what they are.
    static let satelliteLabelSpec = TypeSpec(size: 10, weight: .regular, design: .monospaced, monospacedDigit: true)
    /// Compass bearings. Widest tracking in the app: N/S/E/W must read as
    /// chrome on the horizon, never as the name of something up there.
    static let cardinalLabelSpec = TypeSpec(size: 11, weight: .semibold, design: .rounded, tracking: 1.8)

    // MARK: - Fonts
    //
    // Static constants, resolved once. Views use these.

    static let panelTitle = panelTitleSpec.font
    static let sectionLabel = sectionLabelSpec.font
    static let body = bodySpec.font
    static let bodyNumeric = bodyNumericSpec.font
    static let caption = captionSpec.font
    static let captionNumeric = captionNumericSpec.font
    static let footnote = footnoteSpec.font
    static let footnoteNumeric = footnoteNumericSpec.font
    static let clock = clockSpec.font
    static let readout = readoutSpec.font
    static let badge = badgeSpec.font
    static let control = controlSpec.font

    static let constellationLabel = constellationLabelSpec.font
    static let starLabel = starLabelSpec.font
    static let solarSystemLabel = solarSystemLabelSpec.font
    static let deepSkyLabel = deepSkyLabelSpec.font
    static let satelliteLabel = satelliteLabelSpec.font
    static let cardinalLabel = cardinalLabelSpec.font

    // MARK: - Introspection for tests

    /// Every spec in the scale, with the name it is known by. Used by
    /// `TypographyTests` to assert the invariants above hold across the whole
    /// scale rather than for whichever entries a test happened to name.
    static let allSpecs: [(name: String, spec: TypeSpec)] = [
        ("panelTitle", panelTitleSpec),
        ("sectionLabel", sectionLabelSpec),
        ("body", bodySpec),
        ("bodyNumeric", bodyNumericSpec),
        ("caption", captionSpec),
        ("captionNumeric", captionNumericSpec),
        ("footnote", footnoteSpec),
        ("footnoteNumeric", footnoteNumericSpec),
        ("clock", clockSpec),
        ("readout", readoutSpec),
        ("badge", badgeSpec),
        ("control", controlSpec),
        ("constellationLabel", constellationLabelSpec),
        ("starLabel", starLabelSpec),
        ("solarSystemLabel", solarSystemLabelSpec),
        ("deepSkyLabel", deepSkyLabelSpec),
        ("satelliteLabel", satelliteLabelSpec),
        ("cardinalLabel", cardinalLabelSpec),
    ]

    /// The specs that are ever used to set digits which change under the user's
    /// eye. Every one of these must be monospaced-digit; the test enforces it,
    /// and this list is the checklist that stops a new numeric style being
    /// added without it.
    static let numericSpecNames: Set<String> = [
        "bodyNumeric", "captionNumeric", "footnoteNumeric",
        "clock", "readout", "satelliteLabel",
    ]

    /// The smallest size anything in this app may be set at. Text over a live,
    /// moving, near-black background needs more size than text on a page; 9pt
    /// is where the small print stops and illegibility starts.
    static let legibilityFloor: CGFloat = 9
}

/// The shared geometry of the floating chrome.
///
/// Before this existed, the panels used a 16pt corner radius, the location
/// form's text fields used 6, the badges used capsules, padding was 14 in the
/// glass panel and 6/7/10 inside it, and each view chose its own vertical
/// rhythm. Four panels on screen at once made that read as four different
/// widgets that happened to share a colour.
///
/// The scale is 4-based (4 / 8 / 12 / 16 / 20) because everything else on macOS
/// is, and the radii are `.continuous` throughout so the corners match the
/// window's and the material's.
enum SkyMetrics {
    // MARK: Corner radii
    /// Inset controls inside a panel: text fields, hover targets.
    static let radiusInner: CGFloat = 7
    /// The panels themselves.
    static let radiusPanel: CGFloat = 14

    // MARK: Padding
    /// Gap between a glyph and its adjacent label.
    static let paddingTight: CGFloat = 4
    /// Standard inner gap: between rows in a panel, either side of a divider.
    static let paddingSnug: CGFloat = 8
    /// The panel's own inset from its glass edge.
    static let paddingPanel: CGFloat = 12
    /// The floating controls' inset from the window edge.
    static let paddingScreen: CGFloat = 18

    // MARK: Line rhythm
    /// Vertical spacing between rows of a panel's content.
    static let rowSpacing: CGFloat = 6
    /// Horizontal spacing between the clusters of the time bar.
    static let clusterSpacing: CGFloat = 12

    // MARK: Chrome treatment
    /// One hairline, one shadow, one tint — see `GlassPanel`.
    static let strokeWidth: CGFloat = 1
    static let shadowRadius: CGFloat = 14
    static let shadowYOffset: CGFloat = 6
    static let shadowOpacity: Double = 0.35
    /// How much of the night-sky tint is laid under the material. Enough to
    /// keep the panels from going grey over a bright Milky Way, not enough to
    /// make them read as solid.
    static let panelTintOpacity: Double = 0.30

    /// The square touch/click target used for the icon buttons in the time bar.
    static let iconButtonSize: CGFloat = 20

    /// Every radius in the scale, ascending. Asserted consistent in tests.
    static let radii: [CGFloat] = [radiusInner, radiusPanel]
    /// Every padding step, ascending.
    static let paddings: [CGFloat] = [paddingTight, paddingSnug, paddingPanel, paddingScreen]
}
