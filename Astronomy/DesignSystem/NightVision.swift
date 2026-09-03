//
//  NightVision.swift
//  Astronomy
//
//  Red-on-black observing mode.
//
//  The point of a night-vision mode is not decoration. Rhodopsin regenerates
//  over roughly twenty to thirty minutes in the dark and is bleached again by a
//  single glance at a white screen; deep red light (above ~620 nm) is the part
//  of the spectrum the rod cells are least sensitive to, so a red-only display
//  lets an observer read the screen without paying for it in dark adaptation.
//  That is why this mode is a *colour* transform and not a dimmer: dimming a
//  white panel still bleaches, it just bleaches more slowly.
//
//  Two halves, one switch:
//
//   * **Chrome** — the SwiftUI layer is desaturated and multiplied towards red
//     by `View.nightVision(strength:)`. One modifier on the whole chrome layer,
//     so nothing is special-cased per view and a control added tomorrow is
//     tinted without being told about this file.
//   * **The sky** — the Metal passes apply the same transform in the fragment
//     shaders, driven by one uniform. Doing it on the GPU rather than laying a
//     red filter over the whole window is what keeps the sky *usable*: the
//     transform below is luminance-preserving, so a magnitude-2 star is still
//     exactly as much brighter than a magnitude-5 star as it was, and the
//     twilight gradient still reads as a gradient.
//
//  `redScale` is the single definition of the transform; `Shaders.metal`
//  contains the same four lines in MSL, and `NightVisionTests` pins the two
//  together by asserting the properties both must have.
//

import SwiftUI

enum NightVision {

    /// Rec. 709 luma weights — the same ones the rest of the pipeline's
    /// perceptual reasoning uses.
    static let lumaWeights = (r: 0.2126, g: 0.7152, b: 0.0722)

    /// How much green and blue survive at full strength.
    ///
    /// Not zero, deliberately. A channel-pure red image has no way to render an
    /// antialiased edge except by varying red, which on a dark background reads
    /// as a soft smear rather than an edge, and text set that way is markedly
    /// harder to read than the same text with a trace of the other two channels
    /// carrying the edge. Both values sit far below the threshold where the
    /// display emits enough short-wavelength light to matter for adaptation.
    static let greenResidual = 0.10
    static let blueResidual = 0.055

    /// How long the transition takes, in seconds. Long enough to read as a
    /// wash rather than a switch, short enough not to feel like waiting.
    static let transitionDuration: TimeInterval = 0.55

    /// Relative luminance of a linear-ish RGB triple.
    static func luminance(red r: Double, green g: Double, blue b: Double) -> Double {
        lumaWeights.r * r + lumaWeights.g * g + lumaWeights.b * b
    }

    /// Maps a colour to its red-scale equivalent, interpolated by `strength`.
    ///
    /// The mapped colour puts the source's *luminance* into the red channel
    /// unchanged. That is the property that makes the sky survive the
    /// transform: the ordering and the ratios of every brightness on screen are
    /// preserved exactly, because every one of them is scaled by the same
    /// factor of one. A white star and a white label both become the same red;
    /// a star half as bright becomes a red half as bright.
    static func redScale(
        red r: Double, green g: Double, blue b: Double, strength: Double
    ) -> (red: Double, green: Double, blue: Double) {
        let s = min(1, max(0, strength))
        let y = luminance(red: r, green: g, blue: b)
        return (
            r + (y - r) * s,
            g + (y * greenResidual - g) * s,
            b + (y * blueResidual - b) * s
        )
    }

    /// Smootherstep easing for the transition ramp, so the wash has no visible
    /// start or stop.
    static func ease(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x * x * x * (x * (x * 6 - 15) + 10)
    }

    /// Where the ramp is, `elapsed` seconds after it started at `origin` on its
    /// way to `target`. Pure, so the transition can be asserted without a clock.
    static func ramp(origin: Double, target: Double, elapsed: TimeInterval) -> Double {
        guard elapsed < transitionDuration else { return target }
        guard elapsed > 0 else { return origin }
        return origin + (target - origin) * ease(elapsed / transitionDuration)
    }
}

/// The app's night-vision switch.
///
/// Split from `SkyViewModel` on purpose. `strength` is sampled once per frame
/// by the render path, and `isEnabled` is read by the chrome; keeping them on
/// their own small object means a view that reads the switch does not thereby
/// depend on the view model's several dozen other observable properties, and
/// the sky's per-frame read of `strength` does not invalidate any view body.
@Observable
@MainActor
final class NightVisionController {

    /// The switch itself. Chrome reads this; nothing on the render path does.
    private(set) var isEnabled = false

    /// Where the ramp was when the switch last flipped, and when that was.
    /// Ignored by observation: they change only when `isEnabled` does, and a
    /// view that tracked them would be tracking the same event twice.
    @ObservationIgnored private var rampOrigin: Double = 0
    @ObservationIgnored private var rampStart: Date = .distantPast

    /// The continuous 0...1 ramp the shaders use.
    ///
    /// Computed from the wall clock rather than stepped by a timer, exactly as
    /// `TimeController` computes simulated time: the render loop samples it at
    /// whatever rate the display runs at and sees a smooth curve, and no timer
    /// has to keep pace with a 120 Hz display to make that true.
    var strength: Double {
        NightVision.ramp(
            origin: rampOrigin,
            target: isEnabled ? 1 : 0,
            elapsed: Date().timeIntervalSince(rampStart)
        )
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        rampOrigin = strength
        rampStart = Date()
        isEnabled = enabled
    }

    func toggle() {
        setEnabled(!isEnabled)
    }
}

// MARK: - Chrome tint

extension View {
    /// Re-tints an entire view tree to red-on-black.
    ///
    /// Three stock filters rather than a palette swap, and that is the whole
    /// design: a palette swap would need every colour constant duplicated and
    /// every view taught which set to read, and the first control added
    /// afterwards would be the one that stayed blue. A filter on the chrome
    /// layer's root cannot be forgotten by a new view, and it animates for
    /// free, which is what makes the transition a wash rather than a snap.
    func nightVision(strength: Double) -> some View {
        let s = min(1, max(0, strength))
        return self
            .grayscale(s)
            .colorMultiply(
                Color(
                    red: 1,
                    green: 1 - (1 - NightVision.greenResidual) * s,
                    blue: 1 - (1 - NightVision.blueResidual) * s
                )
            )
            // Chrome under a red filter reads brighter than it measures — the
            // eye has nothing else on screen to scale it against. A few percent
            // off the top keeps the panels sitting behind the sky rather than
            // in front of it.
            .brightness(-0.05 * s)
    }
}
