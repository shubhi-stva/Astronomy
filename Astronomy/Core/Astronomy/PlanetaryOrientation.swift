//
//  PlanetaryOrientation.swift
//  Astronomy
//
//  Where a body's north pole points and which face of it is turned toward
//  Earth right now.
//
//  This exists so the bundled surface maps (see `DATA_SOURCES.md`) are drawn
//  showing the *correct hemisphere*. Painting a Mars texture on a sprite with
//  an arbitrary fixed rotation would put Syrtis Major wherever the sprite
//  happened to start, which looks like detail while telling the user something
//  false. Everything below is the standard IAU construction, using published
//  rotation elements, so the features that face you are the ones that really
//  do.
//
//  Source of the rotation elements
//  -------------------------------
//  Archinal, B. A., Acton, C. H., A'Hearn, M. F., Conrad, A., Consolmagno,
//  G. J., Duxbury, T., Hestroffer, D., Hilton, J. L., Kirk, R. L., Klioner,
//  S. A., McCarthy, D., Meech, K., Oberst, J., Ping, J., Seidelmann, P. K.,
//  Tholen, D. J., Thomas, P. C., and Williams, I. P. (2018),
//  "Report of the IAU Working Group on Cartographic Coordinates and Rotational
//  Elements: 2015", Celestial Mechanics and Dynamical Astronomy 130, 22.
//  DOI 10.1007/s10569-017-9805-5. Values cross-checked against the NAIF
//  planetary constants kernel `pck00011.tpc`, which encodes that report.
//
//  What is modelled and what is not
//  --------------------------------
//  Only the **linear** terms of each expression are used: the pole's secular
//  drift and the uniform rotation of the prime meridian. The small
//  trigonometric nutation/precession terms in the IAU expressions are dropped.
//  Their amplitudes are at the 0.001-degree level for Mars and Jupiter, which
//  is far below one pixel on a disk a few hundred pixels across.
//
//  For the Moon the dropped terms are larger (the *physical* libration), but
//  the effect that actually matters — **optical libration**, the +/- 8 degree
//  wander that reveals the limb regions — comes out of this construction for
//  free, because the sub-Earth point is computed from the Moon's true
//  geocentric direction rather than from a mean one. The residual physical
//  libration is a few hundredths of a degree.
//
//  Everything here is referred to the **equinox of date**, because that is the
//  frame `PlanetPosition` and `MoonPosition` deliver. The IAU elements are
//  J2000, so the pole is precessed forward with the app's existing
//  `Precession` before use.
//

import Foundation
import simd

enum PlanetaryOrientation {

    /// Where a body's north pole points, and which point on its surface faces
    /// Earth, at one instant.
    struct Orientation: Equatable {
        /// Planetocentric longitude of the sub-Earth point, in degrees,
        /// **east-positive**, in the same convention as the bundled maps.
        var subEarthLongitudeDegrees: Double
        /// Planetocentric latitude of the sub-Earth point, in degrees. Positive
        /// means the north pole is tipped toward Earth. This is what shows you
        /// Mars's north polar cap in one apparition and its south in another.
        var subEarthLatitudeDegrees: Double
        /// The body's north pole direction, of date, as a unit vector in
        /// equatorial coordinates. Carried out so the renderer can work out
        /// which way "north" lies on screen.
        var poleDirection: SIMD3<Double>
    }

    /// Linear IAU rotation elements for one body.
    struct RotationElements {
        /// Right ascension of the north pole at J2000, degrees.
        let poleRightAscension: Double
        /// Its drift, degrees per Julian century.
        let poleRightAscensionRate: Double
        /// Declination of the north pole at J2000, degrees.
        let poleDeclination: Double
        /// Its drift, degrees per Julian century.
        let poleDeclinationRate: Double
        /// Prime-meridian angle at J2000, degrees, measured from the ascending
        /// node of the body's equator on the J2000 equator.
        let primeMeridian: Double
        /// Rotation rate, degrees per day.
        let primeMeridianRate: Double
    }

    /// The bodies this app has a surface map for. Deliberately only three —
    /// see `DATA_SOURCES.md` for why the others are not textured.
    static func rotationElements(objectID id: String) -> RotationElements? {
        switch id {
        case "mars":
            // IAU 2015, body 499.
            return RotationElements(
                poleRightAscension: 317.269202, poleRightAscensionRate: -0.10927547,
                poleDeclination: 54.432516, poleDeclinationRate: -0.05827105,
                primeMeridian: 176.049863, primeMeridianRate: 350.891982443297
            )
        case "jupiter":
            // IAU 2015, body 599. The prime meridian is **System III**, the
            // rotation of the magnetic field, which is the standard reference
            // for Jovian longitude. Jupiter has no solid surface, so its
            // visible cloud features drift relative to any fixed system; see
            // the note on the Jupiter map in DATA_SOURCES.md.
            return RotationElements(
                poleRightAscension: 268.056595, poleRightAscensionRate: -0.006499,
                poleDeclination: 64.495303, poleDeclinationRate: 0.002413,
                primeMeridian: 284.95, primeMeridianRate: 870.5360000
            )
        case "moon":
            // IAU 2015, body 301, linear terms only. The Moon is tidally
            // locked, so this rate is also its mean orbital motion and the
            // sub-Earth longitude it produces stays near zero, wandering by
            // the optical libration — which is exactly right.
            return RotationElements(
                poleRightAscension: 269.9949, poleRightAscensionRate: 0.0031,
                poleDeclination: 66.5392, poleDeclinationRate: 0.0130,
                primeMeridian: 38.3213, primeMeridianRate: 13.17635815
            )
        default:
            return nil
        }
    }

    /// True when this body has both rotation elements and a bundled map.
    static func hasSurfaceMap(objectID id: String) -> Bool {
        rotationElements(objectID: id) != nil
    }

    /// The sub-Earth point and pole direction for a body seen in a given
    /// direction at a given time.
    ///
    /// - Parameters:
    ///   - id: the body's object id.
    ///   - equatorial: the body's apparent geocentric position, equinox of
    ///     date — i.e. exactly what the ephemeris hands the renderer.
    ///   - julianDay: the instant, TT-ish. The difference between TT and UTC is
    ///     under a minute and moves Mars's prime meridian by under 0.25 degrees.
    static func orientation(
        objectID id: String,
        equatorial: EquatorialCoordinate,
        julianDay: Double
    ) -> Orientation? {
        guard let elements = rotationElements(objectID: id) else { return nil }

        let d = julianDay - 2_451_545.0
        let t = d / 36525.0

        let alpha0 = elements.poleRightAscension + elements.poleRightAscensionRate * t
        let delta0 = elements.poleDeclination + elements.poleDeclinationRate * t
        // W wraps many times over a long time span; reducing it keeps the
        // float arithmetic honest at the far end of the time machine.
        let w = normalizedDegrees(elements.primeMeridian + elements.primeMeridianRate * d)

        // The IAU pole is J2000; the body's position is of date. Bring the
        // pole into the same frame.
        let poleJ2000 = EquatorialCoordinate(rightAscensionDegrees: alpha0, declinationDegrees: delta0)
        let poleOfDate = Precession.precess(poleJ2000, julianDay: julianDay)
        let pole = simd_normalize(Precession.unitVector(poleOfDate))

        // Direction Earth -> body, and its negation, the direction body ->
        // Earth. The sub-Earth point is where the latter pierces the surface.
        let toBody = simd_normalize(Precession.unitVector(equatorial))
        let toEarth = -toBody

        // Latitude: the angle the Earth direction makes with the body's
        // equatorial plane.
        let sinLatitude = max(-1.0, min(1.0, simd_dot(pole, toEarth)))
        let latitude = asin(sinLatitude) * 180.0 / .pi

        // Longitude. The IAU prime-meridian angle W is measured, along the
        // body's equator and in the direction of rotation, from the ascending
        // node of that equator on the J2000 equator. That node lies along
        // z_hat x pole. (Precessing the pole moves the node by the same tiny
        // amount, which is consistent with using an of-date body direction.)
        let z = SIMD3<Double>(0, 0, 1)
        var node = simd_cross(z, pole)
        let nodeLength = simd_length(node)
        guard nodeLength > 1e-12 else { return nil }   // pole on the celestial pole
        node /= nodeLength

        // Project the Earth direction into the body's equatorial plane and
        // measure its angle east of the node.
        var inPlane = toEarth - pole * SIMD3<Double>(repeating: sinLatitude)
        let inPlaneLength = simd_length(inPlane)
        guard inPlaneLength > 1e-12 else { return nil } // Earth over the pole
        inPlane /= inPlaneLength

        let east = simd_cross(pole, node)
        let angleFromNode = atan2(simd_dot(east, inPlane), simd_dot(node, inPlane)) * 180.0 / .pi

        // A point at east longitude L sits at angle (W + L) from the node, so
        // the sub-Earth longitude is the measured angle minus W.
        let longitude = normalizedDegrees(angleFromNode - w)

        return Orientation(
            subEarthLongitudeDegrees: longitude,
            subEarthLatitudeDegrees: latitude,
            poleDirection: pole
        )
    }

    /// Reduces an angle to 0 ..< 360 degrees.
    static func normalizedDegrees(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360.0)
        return r < 0 ? r + 360.0 : r
    }
}
