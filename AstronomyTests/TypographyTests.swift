//
//  TypographyTests.swift
//  AstronomyTests
//
//  Value-level tests for the type and chrome scales in `Typography.swift`.
//
//  There is a real limit to what is testable here and it is worth being honest
//  about it: `Font` is opaque, so nothing below actually renders anything or
//  measures anything. What these tests protect is the *model* — the invariants
//  the scale claims about itself, which is exactly the thing that erodes when
//  someone adds a style in a hurry. They will catch a numeric readout added
//  without monospaced digits, a size added below the legibility floor, and a
//  hierarchy inverted by a well-meant tweak. They will not catch anything
//  looking wrong, and are not pretending to.
//

import XCTest
import SwiftUI
@testable import Astronomy

final class TypographyTests: XCTestCase {

    // MARK: - The legibility floor

    /// Nothing in the app may be set below 9pt. This is the smallest size at
    /// which small print stays readable over a live, moving, near-black
    /// background, and it is asserted rather than merely commented because it
    /// is the invariant most likely to be broken by "just make it a bit
    /// smaller so it fits".
    func testNoStyleFallsBelowTheLegibilityFloor() {
        for (name, spec) in SkyType.allSpecs {
            XCTAssertGreaterThanOrEqual(
                spec.size, SkyType.legibilityFloor,
                "\(name) is set at \(spec.size)pt, below the \(SkyType.legibilityFloor)pt floor"
            )
        }
    }

    /// And nothing is absurdly large either. This is chrome around a sky; a
    /// 20pt panel title would be the chrome starting to compete with the view.
    func testNoStyleIsLargerThanThePanelTitle() {
        for (name, spec) in SkyType.allSpecs {
            XCTAssertLessThanOrEqual(
                spec.size, SkyType.panelTitleSpec.size,
                "\(name) is larger than the panel title, which should be the largest text in the app"
            )
        }
    }

    // MARK: - Hierarchy

    /// The chrome ramp is strictly descending: title > body > caption >
    /// footnote. If two adjacent steps ever collapse to the same size, one of
    /// them has stopped doing any work and the hierarchy has a hole in it.
    func testChromeScaleIsStrictlyDescending() {
        let ramp: [(String, CGFloat)] = [
            ("panelTitle", SkyType.panelTitleSpec.size),
            ("clock", SkyType.clockSpec.size),
            ("body", SkyType.bodySpec.size),
            ("caption", SkyType.captionSpec.size),
            ("footnote", SkyType.footnoteSpec.size),
        ]
        for (earlier, later) in zip(ramp, ramp.dropFirst()) {
            XCTAssertGreaterThan(
                earlier.1, later.1,
                "\(earlier.0) (\(earlier.1)pt) must be strictly larger than \(later.0) (\(later.1)pt)"
            )
        }
    }

    /// A numeric style always matches the size of its non-numeric sibling.
    /// The whole point of the pairs is that a label and the number beside it
    /// sit on the same line without one of them looking like a different size.
    func testNumericStylesMatchTheirNonNumericSiblings() {
        XCTAssertEqual(SkyType.bodyNumericSpec.size, SkyType.bodySpec.size)
        XCTAssertEqual(SkyType.captionNumericSpec.size, SkyType.captionSpec.size)
        XCTAssertEqual(SkyType.footnoteNumericSpec.size, SkyType.footnoteSpec.size)
    }

    /// Sky labels have their own hierarchy, and it is the one the design
    /// argues for: a planet's name is the loudest thing up there, a star's
    /// name is quieter than it, and both are set lighter than chrome would be
    /// because a dark background makes text look heavier than it is.
    func testSkyLabelHierarchy() {
        XCTAssertLessThan(
            SkyType.starLabelSpec.size, SkyType.solarSystemLabelSpec.size,
            "a star name should be set smaller than a planet name"
        )
        XCTAssertEqual(SkyType.starLabelSpec.weight, .light)
        XCTAssertEqual(SkyType.constellationLabelSpec.weight, .light)
        XCTAssertEqual(SkyType.solarSystemLabelSpec.weight, .medium)
    }

    // MARK: - Monospaced digits

    /// Every style that ever carries a changing number declares monospaced
    /// digits. This is the checklist that stops a new readout being added with
    /// proportional figures and quietly making a panel twitch.
    func testEveryNumericStyleIsMonospacedDigit() {
        for name in SkyType.numericSpecNames {
            guard let entry = SkyType.allSpecs.first(where: { $0.name == name }) else {
                XCTFail("numericSpecNames lists '\(name)', which is not in allSpecs")
                continue
            }
            XCTAssertTrue(
                entry.spec.monospacedDigit,
                "\(name) sets digits that change and must be monospacedDigit"
            )
        }
    }

    /// The converse, so the two lists cannot drift: nothing outside
    /// `numericSpecNames` claims monospaced digits, which would mean the
    /// checklist has gone stale.
    func testOnlyDeclaredNumericStylesAreMonospacedDigit() {
        for (name, spec) in SkyType.allSpecs where spec.monospacedDigit {
            XCTAssertTrue(
                SkyType.numericSpecNames.contains(name),
                "\(name) is monospacedDigit but is not listed in numericSpecNames"
            )
        }
    }

    /// The specific readouts the app is judged on: the clock, the info panel's
    /// value column, the playback rate, the satellite counts, and the
    /// coordinate fields. Named individually because these are the ones a
    /// reviewer would check by hand.
    func testTheReadoutsUsersWatchAreMonospacedDigit() {
        XCTAssertTrue(SkyType.clockSpec.monospacedDigit, "the clock")
        XCTAssertTrue(SkyType.captionNumericSpec.monospacedDigit, "RA/Dec, altitude, azimuth, magnitude")
        XCTAssertTrue(SkyType.readoutSpec.monospacedDigit, "playback rate")
        XCTAssertTrue(SkyType.footnoteNumericSpec.monospacedDigit, "satellite counts, element age")
        XCTAssertTrue(SkyType.bodyNumericSpec.monospacedDigit, "latitude/longitude entry")
        XCTAssertTrue(SkyType.satelliteLabelSpec.monospacedDigit, "satellite designations on the sky")
    }

    // MARK: - Tracking

    /// Tracking is applied where the design says it is — the small tagged caps
    /// and the compass bearings — and nowhere it would be noise. Solar-system
    /// names in particular are set at normal fit; letterspacing a 12pt medium
    /// name would make it read as a label rather than as a name.
    func testTrackingIsAppliedOnlyToTheSmallCapsClasses() {
        XCTAssertGreaterThan(SkyType.sectionLabelSpec.tracking, 0)
        XCTAssertGreaterThan(SkyType.badgeSpec.tracking, 0)
        XCTAssertGreaterThan(SkyType.constellationLabelSpec.tracking, 0)
        XCTAssertEqual(SkyType.solarSystemLabelSpec.tracking, 0)
        XCTAssertEqual(SkyType.bodySpec.tracking, 0)
        XCTAssertEqual(SkyType.panelTitleSpec.tracking, 0)
    }

    /// Cardinal points carry the widest tracking of anything in the app:
    /// they must read as chrome on the horizon, never as the name of an object.
    func testCardinalLabelsAreTheMostWidelyTracked() {
        for (name, spec) in SkyType.allSpecs where name != "cardinalLabel" {
            XCTAssertLessThan(
                spec.tracking, SkyType.cardinalLabelSpec.tracking,
                "\(name) is tracked at least as wide as the compass bearings"
            )
        }
    }

    /// Tracking never goes negative. Tightening letterfit on a dark background
    /// is the wrong direction: it is exactly where letterforms need more air,
    /// not less.
    func testTrackingIsNeverNegative() {
        for (name, spec) in SkyType.allSpecs {
            XCTAssertGreaterThanOrEqual(spec.tracking, 0, "\(name) has negative tracking")
        }
    }

    // MARK: - The scale is a scale

    /// No two styles share a name. Cheap, but `allSpecs` is hand-maintained
    /// and a copy-pasted entry would silently make the monospaced-digit
    /// lookup above test the wrong style.
    func testSpecNamesAreUnique() {
        let names = SkyType.allSpecs.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "duplicate names in SkyType.allSpecs")
    }

    /// `numericSpecNames` refers only to styles that exist.
    func testNumericSpecNamesAllResolve() {
        let names = Set(SkyType.allSpecs.map(\.name))
        for name in SkyType.numericSpecNames {
            XCTAssertTrue(names.contains(name), "numericSpecNames refers to unknown style '\(name)'")
        }
    }

    // MARK: - Chrome metrics

    /// The radii form one ascending scale — inner controls always rounder-
    /// tighter than the panel that contains them. A nested corner with a
    /// *larger* radius than its parent is the classic way a panel starts
    /// looking wrong without anyone being able to say why.
    func testRadiiAscendAndInnerIsTighterThanPanel() {
        XCTAssertEqual(SkyMetrics.radii, SkyMetrics.radii.sorted(), "radii are not in ascending order")
        XCTAssertLessThan(SkyMetrics.radiusInner, SkyMetrics.radiusPanel)
    }

    /// The padding scale is strictly ascending, with no two steps equal — two
    /// identical steps means one of them is redundant and call sites will
    /// start picking between them arbitrarily.
    func testPaddingScaleIsStrictlyAscending() {
        for (a, b) in zip(SkyMetrics.paddings, SkyMetrics.paddings.dropFirst()) {
            XCTAssertLessThan(a, b, "padding scale is not strictly ascending: \(a) then \(b)")
        }
    }

    /// Every padding step is a positive whole number of points. Half-point
    /// padding does not survive contact with a non-Retina display and is never
    /// what anyone meant.
    func testPaddingStepsAreWholePositivePoints() {
        for step in SkyMetrics.paddings {
            XCTAssertGreaterThan(step, 0)
            XCTAssertEqual(step, step.rounded(), "padding step \(step) is not a whole number of points")
        }
    }

    /// The panel's own inset is smaller than the inset from the window edge:
    /// a control should sit further from the screen edge than its content sits
    /// from its own edge, or the whole cluster looks crammed into the corner.
    func testScreenInsetExceedsPanelInset() {
        XCTAssertGreaterThan(SkyMetrics.paddingScreen, SkyMetrics.paddingPanel)
    }

    /// The shadow is restrained. The brief on this app has been consistent —
    /// the sky dominates, the controls are lightweight overlays — and a heavy
    /// drop shadow is the fastest way to make a small pill read as a card.
    func testShadowIsRestrained() {
        XCTAssertLessThanOrEqual(SkyMetrics.shadowOpacity, 0.45, "panel shadow is too dark")
        XCTAssertLessThanOrEqual(SkyMetrics.shadowRadius, 16, "panel shadow is too diffuse")
        XCTAssertGreaterThan(SkyMetrics.shadowYOffset, 0, "the shadow should fall downwards")
        XCTAssertLessThan(SkyMetrics.shadowYOffset, SkyMetrics.shadowRadius,
                          "an offset larger than the blur reads as a hard drop shadow")
    }

    /// The panel tint keeps the glass reading as night sky over a bright Milky
    /// Way, but a control you cannot see through has stopped being an overlay.
    func testPanelTintStaysTranslucent() {
        XCTAssertGreaterThan(SkyMetrics.panelTintOpacity, 0.15, "tint too weak to survive a bright background")
        XCTAssertLessThan(SkyMetrics.panelTintOpacity, 0.5, "tint so strong the panel stops being translucent")
    }

    /// The icon buttons in the time bar stay a comfortable click target.
    func testIconButtonsAreAClickableSize() {
        XCTAssertGreaterThanOrEqual(SkyMetrics.iconButtonSize, 18)
    }
}
