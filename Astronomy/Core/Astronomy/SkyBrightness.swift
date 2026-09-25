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

    /// Faintest magnitude the renderer will draw in a fully dark sky.
    ///
    /// 9.0 is the completeness limit of the bundled catalogue, so "peak
    /// darkness" and "the bottom of the data" are deliberately the same
    /// number: at astronomical night the display stops holding anything back.
    static let darkSkyDisplayCeiling = 9.0

    /// The limit actually used for rendering.
    ///
    /// **This curve is a product choice, not photometry.** The honest physical
    /// answer is `limitingMagnitude` above, which runs from about -3.9 under a
    /// high Sun to 6.5 in a pristine sky; it is left untouched and tested
    /// separately. What the renderer draws instead is a remapping of the same
    /// sky-brightness variable mu onto the range the *display* wants:
    ///
    ///     t     = smoothstep((mu - 3.0) / (21.4 - 3.0))
    ///     limit = daylightDisplayFloor + (darkSkyDisplayCeiling - floor) * t
    ///
    /// Two deliberate departures from physics, in opposite directions:
    ///
    ///   * The daytime end is far too generous. Physically almost nothing but
    ///     the Sun, Moon and Venus survives a noon sky, and rendering that
    ///     literally gives a beautiful, useless empty screen. Every planetarium
    ///     shows the sky *through* the daylight; the floor is where that
    ///     convention lives, and it is unchanged from before so the daytime
    ///     look does not move.
    ///   * The night end is also too generous — 9.0 rather than 6.5 — because
    ///     the screen is not a dark-adapted eye under a real sky. A monitor
    ///     compresses six orders of magnitude of brightness into two, and the
    ///     faint field is the first casualty. Drawing to 9.0 restores the
    ///     *impression* of a dark sky's depth, which is the thing a user
    ///     actually recognises, at the cost of being literally wrong about how
    ///     many stars an eye could resolve.
    ///
    /// The transition is the point: mu climbs steeply through twilight, so the
    /// drawn limit climbs with it and the sky visibly fills in over the two
    /// hours after sunset. Nothing here moves a star — only how many are drawn
    /// and how strongly. Positions stay fully physical.
    ///
    /// Roughly: 5.6 at Sun +45 deg, 5.7 at 0 deg, 7.4 at -6 deg, 8.5 at
    /// -12 deg, 9.0 at -18 deg and below.
    static func displayLimitingMagnitude(sunAltitudeDegrees alt: Double, bortleClass: Int = 3) -> Double {
        let mu = zenithMagnitudesPerSquareArcsecond(sunAltitudeDegrees: alt)
        let dayMu = 3.0, nightMu = 21.4
        let t = min(1.0, max(0.0, (mu - dayMu) / (nightMu - dayMu)))
        let eased = t * t * (3 - 2 * t)
        let limit = daylightDisplayFloor + (darkSkyDisplayCeiling - daylightDisplayFloor) * eased
        // Light pollution only bites once the sky is dark enough for it to be
        // the thing setting the limit; by day the Sun already is.
        return limit - bortleMagnitudePenalty(bortleClass: bortleClass) * eased
    }

    // MARK: - Light pollution

    /// How many magnitudes of the dark-sky display limit a light-polluted site
    /// costs.
    ///
    /// The Bortle scale (Sky & Telescope, 2001) describes classes 1-3 as skies
    /// where the naked-eye limit is 6.5-7+, and the app's dark-sky look was
    /// tuned for exactly that, so those classes cost nothing. From class 4 the
    /// published naked-eye limits fall by roughly 0.4-0.5 magnitude per class
    /// (class 4: 6.1-6.5, class 5: 5.6-6.0, class 6: ~5.5, class 7: ~5.0,
    /// class 8: ~4.5, class 9: ≤4.0); the penalty follows that slope. It is a
    /// display adjustment, applied on the same product curve as the rest of
    /// `displayLimitingMagnitude`, and is documented as such.
    static func bortleMagnitudePenalty(bortleClass: Int) -> Double {
        let bortle = max(1, min(9, bortleClass))
        return bortle <= 3 ? 0 : 0.45 * Double(bortle - 3)
    }

    /// Plain-language name for a Bortle class.
    static func bortleDescription(bortleClass: Int) -> String {
        switch max(1, min(9, bortleClass)) {
        case 1: return "Excellent dark sky"
        case 2: return "Truly dark sky"
        case 3: return "Rural sky"
        case 4: return "Rural/suburban transition"
        case 5: return "Suburban sky"
        case 6: return "Bright suburban sky"
        case 7: return "Suburban/urban transition"
        case 8: return "City sky"
        default: return "Inner-city sky"
        }
    }

    // MARK: - The sky below the horizon (the see-through-Earth view)

    /// Sun altitude governing the sky background for a line of sight that
    /// points *below* the observer's horizon.
    ///
    /// The see-through-Earth view draws the whole celestial sphere, including
    /// the half of it the ground is in the way of. Applying the observer's own
    /// sky brightness to those directions is wrong in a specific, correctable
    /// way: **daylight is an atmospheric foreground.** The blue glow that
    /// drowns out stars is sunlight scattered by the air *along the line of
    /// sight*. A sightline aimed below the horizon does not traverse that
    /// illuminated air — it goes down through the ground, and whatever sky lies
    /// at the far end belongs to a different part of the Earth, quite possibly
    /// the night hemisphere.
    ///
    /// The geometry is exact and elementary. An observer on a sphere of radius
    /// R looking at depression angle |a| below the local horizon sends a chord
    /// into the sphere. The chord and the inward radius meet at 90 - |a|; the
    /// triangle observer-centre-exit is isoceles, so the central angle is
    /// **2|a|**. The sightline therefore leaves the Earth a great-circle
    /// distance of 2|a| away, reaching the exact antipode when a = -90.
    ///
    /// Displacing an observer by a great-circle distance d changes the Sun's
    /// altitude h to
    ///
    ///     sin h' = sin h cos d + cos h sin d cos(psi)
    ///
    /// where psi is the bearing of the displacement relative to the Sun's
    /// azimuth. The app has no reason to prefer one bearing, and the
    /// azimuth-averaged value of the second term is zero, so the model keeps
    /// the first term only:
    ///
    ///     sin h' = sin h cos(2|a|)
    ///
    /// which is continuous at the horizon (d = 0 gives h' = h) and exact at
    /// a = -90 (d = 180 gives h' = -h, the antipode). It is a genuine
    /// derivation rather than a fudge, and it is the whole story: no arbitrary
    /// magnitude bonus is added anywhere.
    static func sightlineSunAltitudeDegrees(
        sunAltitudeDegrees sunAltitude: Double,
        viewAltitudeDegrees viewAltitude: Double
    ) -> Double {
        guard viewAltitude < 0 else { return sunAltitude }
        let d = Angle.degreesToRadians(2.0 * min(90.0, -viewAltitude))
        let sinH = sin(Angle.degreesToRadians(sunAltitude)) * cos(d)
        return Angle.radiansToDegrees(asin(max(-1.0, min(1.0, sinH))))
    }

    /// The Sun altitude that should drive the *displayed* brightness for a
    /// given viewing direction: whichever of the two hemispheres is darker.
    ///
    /// The minimum rather than a straight substitution, because the mechanism
    /// above only ever *removes* a foreground — a sightline through the Earth
    /// can never be dimmed by daylight it does not pass through. In practice:
    ///
    ///  * By day, sub-horizon directions get the night-side value. Looking
    ///    down at noon shows the depth of a dark sky, which is exactly what is
    ///    physically there behind the rock.
    ///  * At night, the far end of the sightline is the *day* hemisphere, so
    ///    the minimum keeps the observer's own dark sky and nothing regresses.
    ///  * Above the horizon it is the observer's own value, unchanged.
    ///
    /// Everything downstream (`displayLimitingMagnitude`, `starContrast`) is
    /// monotone decreasing in Sun altitude, so feeding this single number
    /// through the existing curves gives the darker of the two hemispheres for
    /// both the magnitude limit and the contrast, with no parallel code path.
    static func effectiveSunAltitudeDegrees(
        sunAltitudeDegrees sunAltitude: Double,
        viewAltitudeDegrees viewAltitude: Double
    ) -> Double {
        min(
            sunAltitude,
            sightlineSunAltitudeDegrees(
                sunAltitudeDegrees: sunAltitude, viewAltitudeDegrees: viewAltitude
            )
        )
    }

    /// The darkest effective Sun altitude any direction can reach for a given
    /// real Sun altitude — the value at view altitude -90, where the sightline
    /// reaches the antipode. Used once per frame to size the magnitude scan,
    /// so the spatial/magnitude cull keeps working unchanged.
    static func darkestSightlineSunAltitudeDegrees(sunAltitudeDegrees sunAltitude: Double) -> Double {
        -abs(sunAltitude)
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
