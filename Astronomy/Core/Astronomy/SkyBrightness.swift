//
//  SkyBrightness.swift
//  Astronomy
//
//  How bright is the sky right now, and therefore how faint an object can a
//  naked eye still pick out of it?
//
//  Without this the star catalogue renders at full strength at noon, which is
//  the single most obviously wrong thing a planetarium can do. Stars do not
//  get fainter during the day — the *background* gets brighter, and the
//  contrast that made them visible disappears. So the model here is a
//  background-brightness curve first, and a limiting magnitude derived from
//  it second.
//
//  IMPORTANT — this is an EMPIRICAL FIT, not a photometric model.
//  It is a smooth interpolation through hand-chosen anchor points that
//  reproduce the *observationally familiar* milestones (roughly: the brightest
//  planets survive daylight; the first stars appear around the end of civil
//  twilight; the full naked-eye field is out by astronomical night). It does
//  NOT model:
//    * the Moon's contribution to sky brightness (a full Moon can cost two
//      magnitudes of limiting magnitude — not represented),
//    * artificial light pollution / Bortle class,
//    * airglow, zodiacal light, aurorae, or the seasonal/solar-cycle
//      variation of the natural night-sky floor,
//    * altitude above the horizon (this is a *zenith* brightness; the real
//      sky is brighter near the horizon),
//    * atmospheric extinction of the object itself,
//    * the observer's age, dark adaptation, or averted vision.
//  Anyone wanting the real thing should look at B. E. Schaefer, "Telescopic
//  Limiting Magnitudes", PASP 102, 212 (1990), which does treat most of the
//  above properly.
//

import Foundation

enum SkyBrightness {

    /// Anchor points for the zenith sky background, as (Sun altitude in
    /// degrees, surface brightness in magnitudes per square arcsecond).
    ///
    /// Larger numbers are *darker* — the magnitude scale runs backwards. The
    /// anchors are ordered from highest Sun to lowest, and they straddle the
    /// standard twilight boundaries (-0.833 sunset, -6 civil, -12 nautical,
    /// -18 astronomical) so those transitions land where they should.
    private static let anchors: [(sunAltitude: Double, magPerSquareArcsecond: Double)] = [
        (60.0, 3.0),    // high Sun — full daylight
        (20.0, 3.6),
        (5.0, 4.6),
        (0.0, 6.0),     // Sun on the horizon
        (-0.833, 6.6),  // geometric sunset/sunrise
        (-3.0, 9.0),
        (-6.0, 12.5),   // end of civil twilight
        (-9.0, 15.5),
        (-12.0, 18.0),  // end of nautical twilight
        (-15.0, 20.2),
        (-18.0, 21.4),  // end of astronomical twilight
        (-25.0, 21.9),  // dark-sky floor
    ]

    /// Zenith sky background brightness in mag/arcsec² for a given Sun
    /// altitude. Monotonic and C¹-smooth (smoothstep between anchors), so
    /// scrubbing time never produces a visible step.
    static func zenithMagnitudesPerSquareArcsecond(sunAltitudeDegrees alt: Double) -> Double {
        if alt >= anchors[0].sunAltitude { return anchors[0].magPerSquareArcsecond }
        if alt <= anchors[anchors.count - 1].sunAltitude {
            return anchors[anchors.count - 1].magPerSquareArcsecond
        }
        for i in 0..<(anchors.count - 1) {
            let hi = anchors[i]         // higher Sun
            let lo = anchors[i + 1]     // lower Sun
            if alt <= hi.sunAltitude && alt >= lo.sunAltitude {
                let span = hi.sunAltitude - lo.sunAltitude
                let t = span > 0 ? (hi.sunAltitude - alt) / span : 0
                let s = t * t * (3 - 2 * t)  // smoothstep: zero slope at both anchors
                return hi.magPerSquareArcsecond
                    + (lo.magPerSquareArcsecond - hi.magPerSquareArcsecond) * s
            }
        }
        return anchors[anchors.count - 1].magPerSquareArcsecond
    }

    /// Faintest apparent magnitude a naked eye can pull out of a background of
    /// the given surface brightness.
    ///
    ///     m_lim = 0.55 * mu - 5.55
    ///
    /// A single straight line through the two endpoints we care about most:
    /// a pristine 21.9 mag/arcsec² sky gives m_lim = 6.5 (the textbook
    /// naked-eye limit), and a 3.0 mag/arcsec² midday sky gives m_lim = -3.9
    /// (Venus at -4.2 survives; nothing else but the Sun and Moon does). It
    /// happens to pass within a couple of tenths of the intermediate
    /// twilight anchors too, which is why no higher-order fit is used.
    ///
    /// The slope being ~0.55 rather than 1.0 encodes, crudely, that a point
    /// source competes with a *resolution-element* of background rather than
    /// the whole sky — it is a fit, not a derivation.
    static func nakedEyeLimitingMagnitude(magPerSquareArcsecond mu: Double) -> Double {
        0.55 * mu - 5.55
    }

    /// Convenience: Sun altitude straight through to a limiting magnitude.
    ///
    /// This is the *physical* answer — what an eye could actually pull out of
    /// that background. It is what `displayLimitingMagnitude` is derived from,
    /// and it is deliberately kept separate so the honest number stays
    /// available (and testable) even though the renderer shows more.
    static func limitingMagnitude(sunAltitudeDegrees alt: Double) -> Double {
        nakedEyeLimitingMagnitude(
            magPerSquareArcsecond: zenithMagnitudesPerSquareArcsecond(sunAltitudeDegrees: alt)
        )
    }

    // MARK: - Display model (a product choice, not physics)

    /// Faintest magnitude the renderer will draw, whatever the Sun is doing.
    ///
    /// A planetarium is a tool for answering "what is up there right now",
    /// which means it has to show the sky *through* the daylight — the same
    /// see-through convention every planetarium app uses. Physically the
    /// daytime limit is about -3.9 (only the Sun, Moon and Venus), and
    /// rendering that literally leaves a beautiful but useless empty blue
    /// screen.
    ///
    /// So the display limit is floored here. Note this changes only how many
    /// stars are drawn and how strongly — never *where* they are. Positions
    /// stay fully physical: real catalogue RA/Dec run through the real
    /// observer/time transform, so a star shown at noon is at the exact
    /// altitude and azimuth it genuinely occupies behind the daylight.
    static let daylightDisplayFloor = 5.6

    /// The limit actually used for rendering: the physical limit at night
    /// (which rises above the floor on its own, so dark skies still gain the
    /// faintest stars naturally), and the floor whenever daylight would
    /// otherwise empty the sky.
    static func displayLimitingMagnitude(sunAltitudeDegrees alt: Double) -> Double {
        max(daylightDisplayFloor, limitingMagnitude(sunAltitudeDegrees: alt))
    }

    /// Opacity multiplier applied to stars as the sky background brightens.
    ///
    /// Stars stay visible in daylight, but a bright sky legitimately lowers
    /// their contrast, so drawing them at full night-time intensity against
    /// pale blue looks wrong. This keeps them clearly readable while letting
    /// the sky itself carry the sense of daylight. Ranges from 1.0 in a fully
    /// dark sky to `daylightContrastFloor` under a high Sun.
    static let daylightContrastFloor = 0.72

    static func starContrast(sunAltitudeDegrees alt: Double) -> Double {
        // Track the same brightness curve the colours use, normalised across
        // the range that actually matters (full daylight -> astronomical
        // night), so contrast eases continuously as the sky darkens rather
        // than switching at a threshold.
        let mu = zenithMagnitudesPerSquareArcsecond(sunAltitudeDegrees: alt)
        let dayMu = 3.0, nightMu = 21.4
        let t = min(1.0, max(0.0, (mu - dayMu) / (nightMu - dayMu)))
        let eased = t * t * (3 - 2 * t)
        return daylightContrastFloor + (1.0 - daylightContrastFloor) * eased
    }
}
