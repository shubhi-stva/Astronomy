//
//  PlanetAppearanceTests.swift
//  AstronomyTests
//
//  Pins the *look* of the solar-system bodies: the tints, the aura model, and
//  the zoom ramp that surface detail rides in on.
//
//  These are taste constraints written down as assertions. They exist because
//  taste is exactly the kind of thing that erodes silently across edits — the
//  saturation creeps up one commit at a time until Mars is a stoplight. Each
//  test below states the intent in a range rather than a single value, so
//  there is room to tune without room to ruin.
//

import XCTest
import simd
@testable import Astronomy

final class PlanetColorTests: XCTestCase {

    /// `(max - min) / max` over RGB — the HSV saturation of a colour.
    private func saturation(_ c: SIMD4<Float>) -> Float {
        let hi = max(c.x, max(c.y, c.z))
        let lo = min(c.x, min(c.y, c.z))
        guard hi > 0 else { return 0 }
        return (hi - lo) / hi
    }

    /// HSV value — the brightest channel.
    private func value(_ c: SIMD4<Float>) -> Float {
        max(c.x, max(c.y, c.z))
    }

    private let planetIDs = [
        "mercury", "venus", "mars", "jupiter", "saturn", "uranus", "neptune"
    ]

    // MARK: - Mars, the one the user cares about

    func testMarsIsWarmButNotSaturated() {
        let mars = StarAppearance.planetColor(id: "mars")

        // Warm: red leads, blue trails. This is the ordering that makes it
        // read as Mars at all.
        XCTAssertGreaterThan(mars.x, mars.y, "Mars must be red-leaning")
        XCTAssertGreaterThan(mars.y, mars.z, "Mars must be ochre, not magenta")

        // The whole point. Anything above the ceiling is the fire-engine red
        // the user explicitly rejected; anything below the floor and Mars is
        // just another beige dot.
        let s = saturation(mars)
        XCTAssertTrue(
            StarAppearance.marsSaturationRange.contains(s),
            "Mars saturation \(s) is outside the intended "
            + "\(StarAppearance.marsSaturationRange) — it should read as muted "
            + "ochre/butterscotch, never as a bright red."
        )
    }

    func testMarsIsNotPureRed() {
        let mars = StarAppearance.planetColor(id: "mars")
        // A fire-engine red has green and blue near zero. Ochre does not: its
        // green channel is well over half its red. This is the specific
        // failure mode being guarded against.
        XCTAssertGreaterThan(
            mars.y / mars.x, 0.55,
            "Mars's green channel is too low relative to red — that is a red "
            + "planet, not an ochre one."
        )
        XCTAssertGreaterThan(mars.z, 0.25, "Mars must not have a crushed blue channel")
    }

    // MARK: - The rest of the palette

    func testEveryPlanetTintIsBrightEnoughToReadAsALightSource() {
        for id in planetIDs {
            let c = StarAppearance.planetColor(id: id)
            XCTAssertGreaterThan(value(c), 0.6, "\(id) is too dark to read as a planet")
            XCTAssertLessThanOrEqual(value(c), 1.0, "\(id) exceeds the colour range")
            for channel in [c.x, c.y, c.z] {
                XCTAssertGreaterThanOrEqual(channel, 0.0)
                XCTAssertLessThanOrEqual(channel, 1.0)
            }
            XCTAssertEqual(c.w, 1.0, accuracy: 1e-6, "\(id) tint must be opaque")
        }
    }

    func testNoPlanetIsGarish() {
        // The palette discipline for the whole app: nothing in the sky is a
        // saturated marker colour. Neptune is the most saturated body and even
        // it stays well under a fully saturated blue.
        for id in planetIDs {
            let s = saturation(StarAppearance.planetColor(id: id))
            XCTAssertLessThan(s, 0.60, "\(id) is over-saturated for this palette")
        }
    }

    func testHuesMatchTheRealBodies() {
        let mercury = StarAppearance.planetColor(id: "mercury")
        // Grey: all three channels within a few percent of each other.
        XCTAssertLessThan(saturation(mercury), 0.10, "Mercury should be grey")

        let venus = StarAppearance.planetColor(id: "venus")
        // Pale cream: bright, barely tinted, warm.
        XCTAssertGreaterThan(value(venus), 0.95, "Venus should be brilliant")
        XCTAssertLessThan(saturation(venus), 0.15, "Venus should be near-white")
        XCTAssertGreaterThan(venus.x, venus.z, "Venus's cast is warm, not cool")

        let jupiter = StarAppearance.planetColor(id: "jupiter")
        XCTAssertGreaterThan(jupiter.x, jupiter.z, "Jupiter is a warm tan")

        let saturn = StarAppearance.planetColor(id: "saturn")
        XCTAssertGreaterThan(saturn.x, saturn.z, "Saturn is pale gold")
        // Saturn is a shade less contrasty and yellower than Jupiter.
        XCTAssertLessThan(saturn.z, jupiter.z, "Saturn should be the more golden of the two")

        let uranus = StarAppearance.planetColor(id: "uranus")
        // Pale cyan: green and blue together, both above red.
        XCTAssertGreaterThan(uranus.z, uranus.x, "Uranus is cool")
        XCTAssertGreaterThan(uranus.y, uranus.x, "Uranus is cyan, not blue")
        XCTAssertLessThan(abs(uranus.y - uranus.z), 0.12, "Uranus's green and blue should pair up")

        let neptune = StarAppearance.planetColor(id: "neptune")
        XCTAssertGreaterThan(neptune.z, neptune.y, "Neptune is blue, not cyan")
        XCTAssertGreaterThan(
            neptune.z - neptune.x, uranus.z - uranus.x,
            "Neptune should be the deeper blue of the two ice giants"
        )
    }

    func testStarColourRampIsMonotoneFromBlueToRed() {
        // The B-V ramp was reviewed rather than rewritten; this pins the
        // property that makes it physical. As B-V rises the star gets cooler,
        // so red must not decrease and blue must not increase.
        var previous = StarAppearance.color(colorIndex: -0.4)
        var bv = -0.35
        while bv <= 2.0 {
            let c = StarAppearance.color(colorIndex: bv)
            XCTAssertGreaterThanOrEqual(c.x, previous.x - 1e-5, "red fell at B-V \(bv)")
            XCTAssertLessThanOrEqual(c.z, previous.z + 1e-5, "blue rose at B-V \(bv)")
            previous = c
            bv += 0.05
        }
        // And the extremes stay desaturated: no star is ever a pure hue.
        XCTAssertLessThan(saturation(StarAppearance.color(colorIndex: 2.5)), 0.50)
        XCTAssertLessThan(saturation(StarAppearance.color(colorIndex: -1.0)), 0.40)
    }
}

final class CelestialAuraTests: XCTestCase {

    private func planetAura(magnitude: Double, size: Float, id: String = "mars")
    -> StarAppearance.Aura? {
        StarAppearance.aura(
            kind: .planet,
            magnitude: magnitude,
            tint: StarAppearance.planetColor(id: id),
            pointSize: size
        )
    }

    // MARK: - Who glows, and how much

    func testTheSunGlowsHardest() {
        let sun = StarAppearance.aura(
            kind: .sun, magnitude: -26.7, tint: StarAppearance.sunColor, pointSize: 14
        )
        let moon = StarAppearance.aura(
            kind: .moon, magnitude: -12.7, tint: StarAppearance.moonColor,
            pointSize: 12, illuminatedFraction: 1.0
        )
        let venus = planetAura(magnitude: -4.5, size: 8, id: "venus")

        XCTAssertNotNil(sun)
        XCTAssertNotNil(moon)
        XCTAssertNotNil(venus)
        XCTAssertGreaterThan(sun!.alpha, moon!.alpha, "the Sun must out-bloom the Moon")
        XCTAssertGreaterThan(sun!.alpha, venus!.alpha, "the Sun must out-bloom Venus")
    }

    func testBrighterPlanetsGlowMore() {
        let venus = planetAura(magnitude: -4.5, size: 8)!
        let jupiter = planetAura(magnitude: -2.5, size: 8)!
        let marsOpposition = planetAura(magnitude: -2.0, size: 8)!
        let marsConjunction = planetAura(magnitude: 1.6, size: 8)!
        let saturn = planetAura(magnitude: 0.5, size: 8)!

        XCTAssertGreaterThan(venus.alpha, jupiter.alpha)
        XCTAssertGreaterThan(jupiter.alpha, marsOpposition.alpha)
        XCTAssertGreaterThan(marsOpposition.alpha, saturn.alpha)
        XCTAssertGreaterThan(saturn.alpha, marsConjunction.alpha)
    }

    func testTheIceGiantsDoNotGlow() {
        // Uranus at 5.7 and Neptune at 7.8 are telescopic objects. A halo on
        // either would be a claim about their appearance that is simply false.
        XCTAssertNil(planetAura(magnitude: 5.7, size: 6, id: "uranus"))
        XCTAssertNil(planetAura(magnitude: 7.8, size: 6, id: "neptune"))
    }

    func testNoPlanetAuraIsEverGarish() {
        for magnitude in stride(from: -5.0, through: 3.0, by: 0.25) {
            for size in stride(from: 4.0, through: 260.0, by: 8.0) {
                guard let aura = planetAura(magnitude: magnitude, size: Float(size)) else { continue }
                XCTAssertLessThanOrEqual(
                    aura.alpha, StarAppearance.planetAuraMaximumAlpha + 1e-6,
                    "planet aura alpha exceeded its ceiling at mag \(magnitude), size \(size)"
                )
                XCTAssertGreaterThan(aura.alpha, 0)
                XCTAssertLessThanOrEqual(aura.size, 200.0)
            }
        }
    }

    func testTheAuraIsPulledTowardWhiteSoMarsNeverSmearsRed() {
        let tint = StarAppearance.planetColor(id: "mars")
        let aura = planetAura(magnitude: -2.0, size: 8)!
        // Same hue ordering...
        XCTAssertGreaterThan(aura.color.x, aura.color.y)
        XCTAssertGreaterThan(aura.color.y, aura.color.z)
        // ...but every channel lifted toward white, so the halo is a warm
        // brightening rather than a red stain.
        XCTAssertGreaterThan(aura.color.x, tint.x - 1e-6)
        XCTAssertGreaterThan(aura.color.y, tint.y)
        XCTAssertGreaterThan(aura.color.z, tint.z)
    }

    // MARK: - The aura yields as the disk resolves

    func testAuraFadesAsTheDiskResolves() {
        // The whole reason the damping exists: zoom in and the halo gets out
        // of the way of the thing you zoomed in to see.
        let small = planetAura(magnitude: -2.5, size: 10)!
        let large = planetAura(magnitude: -2.5, size: 200)!
        XCTAssertLessThan(large.alpha, small.alpha * 0.55)
    }

    func testTheMoonAuraNeverDrownsTheTerminator() {
        // At full zoom the Moon's terminator is the feature; the halo must be
        // faint enough to leave it alone.
        let zoomed = StarAppearance.aura(
            kind: .moon, magnitude: -12.7, tint: StarAppearance.moonColor,
            pointSize: 320, illuminatedFraction: 1.0
        )!
        XCTAssertLessThan(zoomed.alpha, 0.11)
        // And a new Moon has almost no halo, because nothing is lit.
        let newMoon = StarAppearance.aura(
            kind: .moon, magnitude: -5, tint: StarAppearance.moonColor,
            pointSize: 12, illuminatedFraction: 0.0
        )!
        let fullMoon = StarAppearance.aura(
            kind: .moon, magnitude: -12.7, tint: StarAppearance.moonColor,
            pointSize: 12, illuminatedFraction: 1.0
        )!
        XCTAssertLessThan(newMoon.alpha, fullMoon.alpha * 0.35)
    }

    func testAuraSizeStopsGrowingOnceTheDiskIsLarge() {
        // The halo is a multiple of the disk at small sizes and a bounded
        // offset from it at large ones, so an extreme zoom cannot fill the
        // frame with glare.
        let ratioSmall = planetAura(magnitude: -4.0, size: 8)!.size / 8
        let ratioLarge = planetAura(magnitude: -4.0, size: 180)!.size / 180
        XCTAssertGreaterThan(ratioSmall, ratioLarge)
    }

    func testStarsAndSatellitesGetNoAuraFromThisPath() {
        // Stars have their own halo model (`glowSize`/`glowAlpha`); satellites
        // and deep-sky objects have none.
        for kind in [CelestialObjectKind.star, .satellite, .deepSky, .constellation] {
            XCTAssertNil(
                StarAppearance.aura(
                    kind: kind, magnitude: -5,
                    tint: SIMD4(1, 1, 1, 1), pointSize: 20
                ),
                "\(kind) should not use the solar-system aura path"
            )
        }
    }

    func testAuraAlphaIsContinuousInSize() {
        // No pop as the user pinches: alpha must not jump between adjacent
        // sizes anywhere along the ramp.
        var previous: Float?
        var size: Float = 4
        while size <= 260 {
            let alpha = planetAura(magnitude: -3.0, size: size)?.alpha ?? 0
            if let previous {
                XCTAssertLessThan(
                    abs(alpha - previous), 0.01,
                    "aura alpha jumped at size \(size)"
                )
            }
            previous = alpha
            size += 0.5
        }
    }

    func testAuraAlphaIsContinuousInMagnitude() {
        // And no pop as a planet brightens toward opposition, including
        // across the threshold where the aura first appears.
        var previous: Float?
        var magnitude = 4.0
        while magnitude >= -5.0 {
            let alpha = planetAura(magnitude: magnitude, size: 10)?.alpha ?? 0
            if let previous {
                XCTAssertLessThan(
                    abs(alpha - previous), 0.01,
                    "aura alpha jumped at magnitude \(magnitude)"
                )
            }
            previous = alpha
            magnitude -= 0.02
        }
    }
}
