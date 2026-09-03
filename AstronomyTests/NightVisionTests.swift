//
//  NightVisionTests.swift
//  AstronomyTests
//
//  The night-vision transform has two implementations — `NightVision.redScale`
//  in Swift and `applyNightVision` in Shaders.metal — and only one of them can
//  be run from a test. So these assert the *properties* the mode is for, which
//  is what actually has to hold on both sides: whites stop being white, the
//  brightness hierarchy of the sky survives, and the switch is a ramp rather
//  than a step.
//

import AppKit
import XCTest
@testable import Astronomy

final class NightVisionTransformTests: XCTestCase {

    func testAtZeroStrengthNothingChanges() {
        let out = NightVision.redScale(red: 0.42, green: 0.62, blue: 0.98, strength: 0)
        XCTAssertEqual(out.red, 0.42, accuracy: 1e-12)
        XCTAssertEqual(out.green, 0.62, accuracy: 1e-12)
        XCTAssertEqual(out.blue, 0.98, accuracy: 1e-12)
    }

    func testWhiteBecomesRed() {
        let out = NightVision.redScale(red: 1, green: 1, blue: 1, strength: 1)
        XCTAssertEqual(out.red, 1.0, accuracy: 1e-9, "white keeps its full luminance in red")
        XCTAssertLessThan(out.green, 0.12)
        XCTAssertLessThan(out.blue, 0.07)
    }

    /// The whole reason the sky is transformed in the shader rather than
    /// filtered as an image: a magnitude ordering that survives the transform.
    func testBrightnessHierarchyIsPreservedExactly() {
        // Three star tints from `StarAppearance`'s family — a blue-white, a
        // white and a deep orange — at descending brightness.
        let samples: [(r: Double, g: Double, b: Double)] = [
            (0.78, 0.85, 1.00),   // hot blue-white, brightest
            (0.55, 0.55, 0.54),   // mid, solar
            (0.22, 0.13, 0.09),   // faint red dwarf
        ]
        let before = samples.map { NightVision.luminance(red: $0.r, green: $0.g, blue: $0.b) }
        let after = samples.map { sample -> Double in
            let out = NightVision.redScale(
                red: sample.r, green: sample.g, blue: sample.b, strength: 1
            )
            return out.red
        }
        // Order preserved...
        XCTAssertTrue(after[0] > after[1] && after[1] > after[2])
        // ...and not merely order: the *ratios* are unchanged, because the
        // transform puts luminance into red untouched.
        for i in samples.indices {
            XCTAssertEqual(after[i], before[i], accuracy: 1e-12)
        }
    }

    /// A black sky must stay black — a red *filter* over the window would lift
    /// it, which is exactly the failure mode this design avoids.
    func testBlackStaysBlack() {
        let out = NightVision.redScale(red: 0, green: 0, blue: 0, strength: 1)
        XCTAssertEqual(out.red, 0, accuracy: 1e-12)
        XCTAssertEqual(out.green, 0, accuracy: 1e-12)
        XCTAssertEqual(out.blue, 0, accuracy: 1e-12)
    }

    /// Legibility: even the dimmest thing the sky draws stays above zero, so
    /// faint stars do not simply disappear when the mode comes on.
    func testFaintStarsSurviveTheTransform() {
        let faint = NightVision.redScale(red: 0.08, green: 0.08, blue: 0.09, strength: 1)
        XCTAssertGreaterThan(faint.red, 0.07)
    }

    func testStrengthIsClamped() {
        let over = NightVision.redScale(red: 1, green: 1, blue: 1, strength: 4)
        let one = NightVision.redScale(red: 1, green: 1, blue: 1, strength: 1)
        XCTAssertEqual(over.green, one.green, accuracy: 1e-12)
        let under = NightVision.redScale(red: 1, green: 1, blue: 1, strength: -2)
        XCTAssertEqual(under.green, 1, accuracy: 1e-12)
    }
}

final class NightVisionRampTests: XCTestCase {

    func testTheRampDoesNotSnap() {
        XCTAssertEqual(NightVision.ramp(origin: 0, target: 1, elapsed: 0), 0, accuracy: 1e-12)
        let quarter = NightVision.ramp(
            origin: 0, target: 1, elapsed: NightVision.transitionDuration * 0.25
        )
        XCTAssertGreaterThan(quarter, 0)
        XCTAssertLessThan(quarter, 0.25, "smootherstep starts slow")
        XCTAssertEqual(
            NightVision.ramp(origin: 0, target: 1, elapsed: NightVision.transitionDuration),
            1, accuracy: 1e-12
        )
    }

    func testTheRampIsMonotonic() {
        var previous = -1.0
        for step in 0...40 {
            let t = NightVision.transitionDuration * Double(step) / 40
            let value = NightVision.ramp(origin: 0, target: 1, elapsed: t)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    /// Flipping the switch mid-transition has to continue from where the ramp
    /// actually is, not from the end it never reached.
    func testReversingMidTransitionStartsFromWhereItWas() {
        let midway = NightVision.ramp(
            origin: 0, target: 1, elapsed: NightVision.transitionDuration * 0.5
        )
        XCTAssertEqual(
            NightVision.ramp(origin: midway, target: 0, elapsed: 0), midway, accuracy: 1e-12
        )
    }
}

/// The uniform actually reaches the GPU. The shader itself cannot be run here,
/// but the plumbing that feeds it can be.
final class NightVisionUniformTests: XCTestCase {

    func testTheStrengthReachesTheBackgroundUniforms() {
        var frame = SkyFrameData.empty
        frame.viewportSize = CGSize(width: 800, height: 600)
        frame.nightVisionStrength = 0.42
        let uniforms = SkyBackgroundUniforms.make(frameData: frame)
        XCTAssertEqual(uniforms.nightVisionStrength, 0.42, accuracy: 1e-6)
    }

    func testTheDefaultIsOff() {
        var frame = SkyFrameData.empty
        frame.viewportSize = CGSize(width: 800, height: 600)
        XCTAssertEqual(SkyBackgroundUniforms.make(frameData: frame).nightVisionStrength, 0)
        XCTAssertEqual(ChromeUniforms().nightVisionStrength, 0)
    }

    /// Night vision must not change what the CPU builds — it is a colour
    /// transform in the fragment shaders and nothing else. If it ever starts
    /// costing geometry, this fails.
    func testTurningItOnDoesNotChangeTheGeometry() {
        var frame = SkyFrameData.empty
        frame.viewportSize = CGSize(width: 1600, height: 1000)
        frame.observerLocation = GeographicLocation(
            latitudeDegrees: 37.5, longitudeDegrees: -122.0
        )
        frame.julianDay = 2_460_000.5
        frame.cameraCenter = HorizontalCoordinate(altitudeDegrees: 45, azimuthDegrees: 180)
        frame.cameraFieldOfViewDegrees = 60
        frame.sunHorizontal = HorizontalCoordinate(altitudeDegrees: -40, azimuthDegrees: 90)
        frame.solarSystemObjects = EphemerisService.solarSystemObjects(julianDay: frame.julianDay)
        var stars: [Star] = []
        var byID: [Int: Star] = [:]
        for i in 0..<400 {
            let star = Star(
                id: i, name: nil,
                ra: Double(i % 40) * 9.0, dec: -80 + Double(i % 20) * 8.0,
                magnitude: Double(i % 60) / 10.0, colorIndex: 0.5, spectralType: nil
            )
            stars.append(star)
            byID[i] = star
        }
        frame.stars = stars
        frame.starsByID = byID

        var off = SkyGeometryBuilder(frameData: frame)
        off.run()

        frame.nightVisionStrength = 1
        var on = SkyGeometryBuilder(frameData: frame)
        on.run()

        XCTAssertEqual(off.pointVertices.count, on.pointVertices.count)
        XCTAssertEqual(off.lineVertices.count, on.lineVertices.count)
        XCTAssertEqual(off.labelCandidates.count, on.labelCandidates.count)
    }
}

final class KeyCommandRoutingTests: XCTestCase {

    func testCommandKOpensThePalette() {
        XCTAssertEqual(
            KeyCommand(characters: "k", modifiers: [.command], keyCode: 40, isEditing: false),
            .openCommandPalette
        )
        // Still works while the user is typing — that is the point of ⌘K.
        XCTAssertEqual(
            KeyCommand(characters: "K", modifiers: [.command], keyCode: 40, isEditing: true),
            .openCommandPalette
        )
    }

    func testShiftCommandKIsNotThePalette() {
        XCTAssertNil(
            KeyCommand(
                characters: "k", modifiers: [.command, .shift], keyCode: 40, isEditing: false
            )
        )
    }

    func testBareNTogglesNightVision() {
        XCTAssertEqual(
            KeyCommand(characters: "n", modifiers: [], keyCode: 45, isEditing: false),
            .toggleNightVision
        )
    }

    /// The reason this routing is a function of `isEditing` at all: typing the
    /// letter n into the search field must type an n.
    func testNIsNotStolenWhileTyping() {
        XCTAssertNil(KeyCommand(characters: "n", modifiers: [], keyCode: 45, isEditing: true))
    }

    func testModifiedNIsNotTheShortcut() {
        XCTAssertNil(
            KeyCommand(characters: "n", modifiers: [.option], keyCode: 45, isEditing: false)
        )
    }

    func testEscapeDismissesEvenWhileTyping() {
        XCTAssertEqual(
            KeyCommand(
                characters: "", modifiers: [], keyCode: KeyCommand.escapeKeyCode, isEditing: true
            ),
            .dismiss
        )
    }

    func testUnmappedKeysAreIgnored() {
        XCTAssertNil(KeyCommand(characters: "q", modifiers: [], keyCode: 12, isEditing: false))
    }
}
