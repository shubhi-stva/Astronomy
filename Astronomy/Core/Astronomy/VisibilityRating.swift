//
//  VisibilityRating.swift
//  Astronomy
//
//  "How well can I actually see this tonight?", answered from physical
//  quantities rather than from a made-up score.
//
//  The founding brief for this app says it explicitly: *avoid arbitrary
//  scores; define the reasoning behind the visibility calculation.* So there is
//  no weighted sum here, and no 0-100 number. Instead there are four
//  independent physical constraints, each with its own documented thresholds,
//  and the rating is the **worst** of them — a limiting-factor model. That has
//  three properties a weighted score does not:
//
//    * every band boundary is a statement about the sky, not a tuning knob;
//    * no amount of goodness in one constraint can hide a fatal problem in
//      another (a magnitude-4 nebula three degrees above the horizon is not
//      "quite good on average", it is unobservable);
//    * the model can always name *why* — `limitingFactor` is the constraint
//      that produced the band, which is the single most useful thing to show a
//      person deciding where to point a telescope.
//
//  The four constraints
//  --------------------
//
//  1. **Altitude / airmass.** How much atmosphere the light traverses. Airmass
//     is Kasten & Young (1989):
//
//         X = 1 / (sin h + 0.50572 * (h + 6.07995)^-1.6364)
//
//     which is accurate to better than 1% down to the horizon, unlike sec(z).
//     Extinction removes `k * X` magnitudes with `k ~ 0.28 mag/airmass` in V at
//     a clear, moderately dark site (a standard value; see e.g. Schaefer's
//     visual-limiting-magnitude work). The bands are set on altitude because
//     that is what an observer reads off the sky:
//
//         >= 40 deg  (X <= 1.56, 0.44 mag lost)   Excellent
//         >= 25 deg  (X <= 2.37, 0.66 mag lost)   Good
//         >= 10 deg  (X <= 5.60, 1.57 mag lost)   Difficult
//         <  10 deg                               Not visible
//
//     The 10-degree floor is not an extinction threshold alone: below it the
//     object is also in the worst seeing, the most light pollution and, in this
//     app, behind the terrain profile.
//
//  2. **Time in true darkness.** Peak altitude is worthless if the object only
//     reaches it during twilight. The quantity is the number of hours the
//     object spends above `usefulAltitudeDegrees` (25 deg) *while the Sun is
//     below -18 deg*:
//
//         >= 2.0 h    Excellent
//         >= 1.0 h    Good
//         >  0.0 h    Difficult
//         =  0.0 h    Not visible tonight
//
//     Two hours is roughly what a deep-sky session on one object costs once
//     finding, dark-adapting and observing are included; one hour is enough for
//     a look; zero means come back another night.
//
//  3. **Sky brightness from the Moon.** Not a penalty coefficient — an actual
//     surface brightness in mag/arcsec^2, so it can be compared to the target's
//     own surface brightness. Two published anchors fix the scale: a dark
//     moonless V sky is about **21.8 mag/arcsec^2**, and a full Moon high in
//     the sky drives it to roughly **18.5 mag/arcsec^2** near the Moon. The
//     model interpolates between them from the quantities we have:
//
//         moonImpact = k^1.5 * separationFactor * upFraction
//         separationFactor = 0.35 + 0.65 * (1 - min(rho, 120) / 120)
//         skyBrightness = 21.8 - 3.5 * moonImpact
//
//     `k` is the illuminated fraction (the `k^1.5` makes a half Moon about a
//     third of a full one, which matches how little a quarter Moon actually
//     hurts); `rho` is the Moon-target angular separation, with a floor of 0.35
//     at large separation because moonlight scatters across the whole sky, not
//     just near the Moon; `upFraction` is the fraction of the object's dark
//     window during which the Moon is above the horizon — a Moon that has set
//     costs nothing. Full Moon at 20 deg separation gives 18.7; at 90 deg,
//     20.0; new Moon, 21.8.
//
//  4. **Contrast / detectability**, evaluated against that sky brightness.
//     Two cases, because the physics differs:
//
//     *Extended objects* (a measured major axis) are limited by **surface
//     brightness**, not integrated magnitude — this is why M33 at magnitude 5.7
//     is harder than many magnitude-9 galaxies. Mean surface brightness inside
//     the ellipse:
//
//         SB = m + 2.5 * log10(pi * a * b)          [a, b semi-axes in arcsec]
//
//     and the constraint is the contrast against the sky, in mag/arcsec^2:
//
//         C = skyBrightness - SB - k_ext * X
//
//         C >= 1.5   Excellent
//         C >= 0.5   Good
//         C >= -1.0  Difficult   (visible with averted vision / at the eyepiece)
//         C <  -1.0  Not visible
//
//     *Point sources* (stars, planets, and catalogue entries with no size) are
//     limited by the point-source limiting magnitude. The naked-eye limit under
//     a 21.8 sky is taken as 6.5, so `m_lim = skyBrightness - 15.3`, scaled by
//     aperture in the usual way:
//
//         m_lim = skyBrightness - 15.3 + 5 * log10(aperture / 7mm)
//
//     with a default aperture of 80 mm — a small telescope or large binocular,
//     which is what "what should I look at tonight" usually means. Under a dark
//     sky that gives 11.8, which is the right order for an 80 mm instrument.
//     The constraint is the margin `m_lim - (m + k_ext * X)`:
//
//         >= 2.0     Excellent
//         >= 1.0     Good
//         >= 0.0     Difficult
//         <  0.0     Not visible
//
//  Every number above is either a published constant, a definition, or an
//  observing convention stated as such. None of them is a weight.
//

import Foundation

/// The four bands. Ordered, so `min` means "worst constraint wins".
nonisolated enum VisibilityBand: Int, Comparable, CaseIterable {
    case notVisible = 0
    case difficult = 1
    case good = 2
    case excellent = 3

    static func < (lhs: VisibilityBand, rhs: VisibilityBand) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .excellent: return "Excellent"
        case .good: return "Good"
        case .difficult: return "Difficult"
        case .notVisible: return "Not visible"
        }
    }
}

/// Which physical constraint produced the band.
nonisolated enum VisibilityConstraint: String {
    case altitude = "Altitude"
    case darkTime = "Time in darkness"
    case moonlight = "Moonlight"
    case contrast = "Contrast"
    case brightness = "Brightness"
}

/// The full, inspectable answer: the band, the constraint that set it, and
/// every intermediate physical quantity, so the UI can explain itself and the
/// tests can assert on the physics rather than on the verdict.
nonisolated struct VisibilityAssessment {
    let band: VisibilityBand
    let limitingFactor: VisibilityConstraint
    /// Highest altitude the object reaches during the night, in degrees.
    let peakAltitudeDegrees: Double
    /// Airmass at that peak altitude (Kasten & Young 1989).
    let airmassAtPeak: Double
    /// Hours above `usefulAltitudeDegrees` while the Sun is below -18 deg.
    let hoursInDarkness: Double
    /// Modelled sky surface brightness during the dark window, mag/arcsec^2.
    let skyBrightnessMagPerSquareArcsec: Double
    /// Moon-target angular separation at the object's transit, in degrees.
    let moonSeparationDegrees: Double
    /// The object's own mean surface brightness, for extended objects only.
    let surfaceBrightnessMagPerSquareArcsec: Double?
    /// Extended objects: sky minus target surface brightness (mag/arcsec^2).
    /// Point sources: limiting magnitude minus extincted magnitude.
    let detectionMarginMagnitudes: Double

    var isObservable: Bool { band > .notVisible }
}

nonisolated enum VisibilityRating {

    // MARK: - Documented constants

    /// V-band atmospheric extinction coefficient, magnitudes per airmass, at a
    /// clear moderately dark site.
    static let extinctionCoefficient: Double = 0.28

    /// Zenith surface brightness of a dark, moonless V sky, mag/arcsec^2.
    static let darkSkyBrightness: Double = 21.8

    /// How far moonlight can drive the sky brightness down from the dark-sky
    /// value, in magnitudes. Calibrated so a high full Moon near the target
    /// gives ~18.5, the standard full-Moon figure.
    static let maximumMoonBrightening: Double = 3.5

    /// Separation, in degrees, beyond which the Moon's proximity stops
    /// mattering and only its all-sky scattered component remains.
    static let moonSeparationSaturationDegrees: Double = 120

    /// The residual all-sky share of the moonlight penalty at large separation.
    static let moonScatteredFloor: Double = 0.35

    /// Altitude above which an object counts as "usefully placed" when
    /// accumulating time in darkness.
    static let usefulAltitudeDegrees: Double = 25

    /// Assumed aperture, in millimetres. 80 mm is a small refractor or a large
    /// binocular; 7 mm is the dark-adapted pupil the naked-eye limit refers to.
    static let assumedApertureMillimetres: Double = 80
    static let eyePupilMillimetres: Double = 7
    /// Naked-eye limiting magnitude under a 21.8 mag/arcsec^2 sky.
    static let nakedEyeLimitUnderDarkSky: Double = 6.5

    // Band thresholds, all named so the tests assert against the same numbers
    // the documentation quotes.
    static let excellentAltitudeDegrees: Double = 40
    static let goodAltitudeDegrees: Double = 25
    static let minimumUsableAltitudeDegrees: Double = 10

    static let excellentDarkHours: Double = 2.0
    static let goodDarkHours: Double = 1.0

    static let excellentContrast: Double = 1.5
    static let goodContrast: Double = 0.5
    static let difficultContrast: Double = -1.0

    static let excellentMagnitudeMargin: Double = 2.0
    static let goodMagnitudeMargin: Double = 1.0

    /// Moonlight is only ever *reported* as the limiting factor when it has
    /// genuinely taken the sky apart; below this impact it is folded into the
    /// contrast term and nothing else.
    static let severeMoonImpact: Double = 0.55
    static let noticeableMoonImpact: Double = 0.25

    // MARK: - Physics

    /// Relative airmass, Kasten & Young (1989). Better than 1% to the horizon,
    /// where `sec(z)` diverges.
    static func airmass(altitudeDegrees h: Double) -> Double {
        guard h > -1 else { return 40 }
        let sinH = sin(Angle.degreesToRadians(max(h, 0)))
        let denominator = sinH + 0.50572 * pow(max(h, 0) + 6.07995, -1.6364)
        return min(40, 1.0 / max(denominator, 1e-6))
    }

    /// Mean surface brightness inside the object's ellipse, mag/arcsec^2.
    /// `m + 2.5 log10(area in square arcsec)` with the area of the ellipse.
    /// Returns nil for an object with no measured extent — a point source has
    /// no surface brightness.
    static func surfaceBrightness(
        magnitude: Double, majorAxisArcmin: Double?, minorAxisArcmin: Double?
    ) -> Double? {
        guard let major = majorAxisArcmin, major > 0 else { return nil }
        let minor = minorAxisArcmin.map { $0 > 0 ? $0 : major } ?? major
        // Semi-axes, arcminutes -> arcseconds.
        let a = major * 60.0 / 2.0
        let b = minor * 60.0 / 2.0
        let areaSquareArcsec = Double.pi * a * b
        return magnitude + 2.5 * log10(areaSquareArcsec)
    }

    /// Dimensionless moonlight impact, 0 (no Moon) ... 1 (full Moon, close,
    /// up all night). See the file comment for each factor's justification.
    static func moonImpact(
        illuminatedFraction k: Double,
        separationDegrees rho: Double,
        moonUpFractionOfDarkWindow upFraction: Double
    ) -> Double {
        let illumination = pow(max(0, min(1, k)), 1.5)
        let clampedSeparation = max(0, min(moonSeparationSaturationDegrees, rho))
        let separationFactor = moonScatteredFloor
            + (1 - moonScatteredFloor) * (1 - clampedSeparation / moonSeparationSaturationDegrees)
        return illumination * separationFactor * max(0, min(1, upFraction))
    }

    /// Sky surface brightness under that impact, mag/arcsec^2.
    static func skyBrightness(moonImpact impact: Double) -> Double {
        darkSkyBrightness - maximumMoonBrightening * max(0, min(1, impact))
    }

    /// Point-source limiting magnitude for the assumed instrument under a sky
    /// of the given surface brightness.
    static func limitingMagnitude(skyBrightness sky: Double) -> Double {
        let apertureGain = 5.0 * log10(assumedApertureMillimetres / eyePupilMillimetres)
        return sky - (darkSkyBrightness - nakedEyeLimitUnderDarkSky) + apertureGain
    }

    // MARK: - The four constraints

    static func altitudeBand(peakAltitudeDegrees h: Double) -> VisibilityBand {
        if h >= excellentAltitudeDegrees { return .excellent }
        if h >= goodAltitudeDegrees { return .good }
        if h >= minimumUsableAltitudeDegrees { return .difficult }
        return .notVisible
    }

    static func darkTimeBand(hours: Double) -> VisibilityBand {
        if hours >= excellentDarkHours { return .excellent }
        if hours >= goodDarkHours { return .good }
        if hours > 0 { return .difficult }
        return .notVisible
    }

    /// The Moon constraint proper. Moonlight never on its own makes a target
    /// *invisible* — that is the contrast term's job, and it already carries
    /// the moonlit sky brightness. This constraint exists so that a badly
    /// moonlit night cannot be reported as "Excellent" for a deep-sky target
    /// however favourable everything else looks.
    static func moonlightBand(impact: Double) -> VisibilityBand {
        if impact >= severeMoonImpact { return .difficult }
        if impact >= noticeableMoonImpact { return .good }
        return .excellent
    }

    static func contrastBand(_ contrast: Double) -> VisibilityBand {
        if contrast >= excellentContrast { return .excellent }
        if contrast >= goodContrast { return .good }
        if contrast >= difficultContrast { return .difficult }
        return .notVisible
    }

    static func magnitudeMarginBand(_ margin: Double) -> VisibilityBand {
        if margin >= excellentMagnitudeMargin { return .excellent }
        if margin >= goodMagnitudeMargin { return .good }
        if margin >= 0 { return .difficult }
        return .notVisible
    }

    // MARK: - Assembly

    /// Combines the four constraints. The band is the worst of them; the
    /// limiting factor is the constraint that produced it (ties broken in the
    /// order altitude, dark time, contrast/brightness, moonlight — i.e. the
    /// most fundamental obstacle first).
    static func assess(
        magnitude: Double,
        majorAxisArcmin: Double?,
        minorAxisArcmin: Double?,
        peakAltitudeDegrees: Double,
        hoursInDarkness: Double,
        moonIlluminatedFraction: Double,
        moonSeparationDegrees: Double,
        moonUpFractionOfDarkWindow: Double
    ) -> VisibilityAssessment {
        let impact = moonImpact(
            illuminatedFraction: moonIlluminatedFraction,
            separationDegrees: moonSeparationDegrees,
            moonUpFractionOfDarkWindow: moonUpFractionOfDarkWindow
        )
        let sky = skyBrightness(moonImpact: impact)
        let airmassAtPeak = airmass(altitudeDegrees: peakAltitudeDegrees)
        let extinction = extinctionCoefficient * airmassAtPeak

        let surface = surfaceBrightness(
            magnitude: magnitude,
            majorAxisArcmin: majorAxisArcmin,
            minorAxisArcmin: minorAxisArcmin
        )

        let detectionConstraint: VisibilityConstraint
        let margin: Double
        let detectionBand: VisibilityBand
        if let surface {
            margin = sky - surface - extinction
            detectionBand = contrastBand(margin)
            detectionConstraint = .contrast
        } else {
            margin = limitingMagnitude(skyBrightness: sky) - (magnitude + extinction)
            detectionBand = magnitudeMarginBand(margin)
            detectionConstraint = .brightness
        }

        let candidates: [(VisibilityBand, VisibilityConstraint)] = [
            (altitudeBand(peakAltitudeDegrees: peakAltitudeDegrees), .altitude),
            (darkTimeBand(hours: hoursInDarkness), .darkTime),
            (detectionBand, detectionConstraint),
            (moonlightBand(impact: impact), .moonlight),
        ]
        // `min(by:)` keeps the first element on a tie, and the array is already
        // ordered most-fundamental-first, so ties resolve as documented.
        let worst = candidates.min { $0.0 < $1.0 }!

        return VisibilityAssessment(
            band: worst.0,
            limitingFactor: worst.1,
            peakAltitudeDegrees: peakAltitudeDegrees,
            airmassAtPeak: airmassAtPeak,
            hoursInDarkness: hoursInDarkness,
            skyBrightnessMagPerSquareArcsec: sky,
            moonSeparationDegrees: moonSeparationDegrees,
            surfaceBrightnessMagPerSquareArcsec: surface,
            detectionMarginMagnitudes: margin
        )
    }

    /// Great-circle separation between two equatorial positions, in degrees.
    static func angularSeparationDegrees(
        _ a: EquatorialCoordinate, _ b: EquatorialCoordinate
    ) -> Double {
        let d1 = Angle.degreesToRadians(a.declinationDegrees)
        let d2 = Angle.degreesToRadians(b.declinationDegrees)
        let dRA = Angle.degreesToRadians(a.rightAscensionDegrees - b.rightAscensionDegrees)
        let cosTheta = sin(d1) * sin(d2) + cos(d1) * cos(d2) * cos(dRA)
        return Angle.radiansToDegrees(acos(max(-1, min(1, cosTheta))))
    }
}
