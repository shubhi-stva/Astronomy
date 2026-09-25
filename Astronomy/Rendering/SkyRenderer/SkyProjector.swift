//
//  SkyProjector.swift
//  Astronomy
//
//  The per-frame projection, with everything that does not depend on the
//  object hoisted out of the loop.
//
//  Why this exists
//  ---------------
//  The geometry builder projects on the order of a thousand catalogue
//  positions per frame. The path it used to take, per object, was:
//
//    RA/Dec  -> unit vector      (2 sin, 2 cos)
//            -> precession matrix
//            -> RA/Dec           (2 atan2, 1 sqrt)
//            -> Alt/Az           (sin/cos of dec, lat and hour angle; asin;
//                                 atan2; tan — plus a *full recomputation of
//                                 sidereal time* per object)
//            -> unit vector      (2 sin, 2 cos)
//            -> screen           (which recomputed the camera's own direction,
//                                 its basis, and the FOV edge scale for every
//                                 object as well)
//
//  Every one of those intermediate angles is thrown away. The composition
//  J2000-equatorial -> horizontal Cartesian is a *rotation*, and a rotation
//  composes: it can be collapsed into one 3x3 matrix built once per frame.
//  What is left per object is a unit vector, a matrix multiply and three dot
//  products, with no inverse trigonometry at all.
//
//  Exactness
//  ---------
//  This is the same transform, not an approximation of it. Writing
//  `u` for the hour-angle frame vector and `L` for local sidereal time:
//
//      u = H . P . v,   H = [[cosL,  sinL, 0],
//                            [sinL, -cosL, 0],
//                            [   0,     0, 1]]
//
//  reproduces `u = (cos d cos h, cos d sin h, sin d)` with `h = L - RA`
//  exactly, by the cosine/sine difference identities. And Meeus 13.5/13.6,
//  rearranged into the (East, Zenith, -North) basis this app uses, are
//
//      E = -u_y
//      Z = u_x cos(lat) + u_z sin(lat)
//      N' = u_x sin(lat) - u_z cos(lat)
//
//  which is the matrix `M` below. `M . H . P` is therefore identical to the
//  old chain up to double-precision rounding (parts in 1e-16, or micro-
//  arcseconds), and `SkyProjectorTests` asserts exactly that against the
//  original implementation.
//
//  Alt/az is still available — the terrain dimming model needs it — but it is
//  now computed *on demand*, for the objects that survive the on-screen test,
//  rather than for everything the cull hands over.
//

import CoreGraphics
import Foundation
import simd

/// Immutable per-frame projection state. Build one per frame, use it for
/// every object.
nonisolated struct SkyProjector {

    /// J2000 mean equatorial -> horizontal Cartesian (X east, Y zenith,
    /// Z south), including precession and nutation to the true equinox of
    /// date. Aberration is applied separately per object (`aberration`).
    let j2000ToHorizontal: simd_double3x3
    /// True-equinox-of-date equatorial -> horizontal Cartesian. Used by the
    /// solar-system bodies, whose ephemerides already produce apparent
    /// of-date positions.
    let ofDateToHorizontal: simd_double3x3
    /// Annual aberration displacement in the horizontal frame: added to a
    /// catalogue direction before renormalising. See `ApparentFrame`.
    let aberration: SIMD3<Double>

    /// Camera direction and its screen basis, in the horizontal frame.
    let centerDirection: SIMD3<Double>
    let right: SIMD3<Double>
    let up: SIMD3<Double>

    /// Tangent-plane units per NDC unit for this field of view.
    let edgeScale: Double
    /// Viewport aspect correction applied to Y.
    let aspectScaleY: Double

    /// Whether directions are lifted by atmospheric refraction before
    /// projection.
    ///
    /// Set only by the frame.
    ///
    /// Deliberately *not* also gated on "is anything in this viewport low
    /// enough for refraction to matter". That optimisation is tempting — the
    /// correction is 3.5 arcminutes at 15 degrees and falls off fast — and it
    /// is wrong: turning the model off for the whole frame shifts every object
    /// in it, so panning across the threshold would step the entire sky by an
    /// arcminute or two. At the narrowest field this app offers that is several
    /// pixels, and a jump the user can see while panning is far worse than the
    /// cost of the lookup that avoids it. See `Refraction.Table`, which is
    /// built to make always-on affordable.
    let refractionEnabled: Bool
    private let refraction = Refraction.Table.shared

    /// The full reduction: precession, nutation, aberration, apparent sidereal
    /// time, and (if the frame asks for it) refraction.
    init(frameData: SkyFrameData, apparentFrame: ApparentFrame) {
        self.init(
            frameData: frameData,
            j2000ToTrueOfDate: apparentFrame.j2000ToTrueOfDate,
            aberration: apparentFrame.aberration,
            greenwichSiderealDegrees: apparentFrame.greenwichApparentSiderealDegrees
        )
    }

    /// Precession only: no nutation, no aberration, no refraction.
    ///
    /// Kept for the equivalence tests, which pin the fused `M·H·P` matrix
    /// against the step-by-step chain through `CoordinateTransformService`.
    /// The sidereal time is whatever that chain uses — apparent, since the
    /// app's places are apparent — so the two sides differ only in the
    /// corrections this initialiser deliberately omits, which is exactly what
    /// makes the comparison meaningful.
    init(frameData: SkyFrameData, precessionMatrix: simd_double3x3) {
        var reduced = frameData
        reduced.refractionEnabled = false
        self.init(
            frameData: reduced,
            j2000ToTrueOfDate: precessionMatrix,
            aberration: .zero,
            greenwichSiderealDegrees: CoordinateTransformService.greenwichApparentSiderealTimeDegrees(
                julianDay: frameData.julianDay
            )
        )
    }

    private init(
        frameData: SkyFrameData,
        j2000ToTrueOfDate: simd_double3x3,
        aberration: SIMD3<Double>,
        greenwichSiderealDegrees: Double
    ) {
        let lst = Angle.degreesToRadians(
            Angle.normalizeDegrees(greenwichSiderealDegrees + frameData.observerLocation.longitudeDegrees)
        )
        let latitude = Angle.degreesToRadians(frameData.observerLocation.latitudeDegrees)

        let cosL = cos(lst), sinL = sin(lst)
        let cosLat = cos(latitude), sinLat = sin(latitude)

        // Rows, spelled out; `simd_double3x3` takes columns, so the
        // initialisers below are transposed relative to how they read.
        // H: equatorial of date -> hour-angle frame.
        let h = simd_double3x3(
            SIMD3(cosL, sinL, 0),
            SIMD3(sinL, -cosL, 0),
            SIMD3(0, 0, 1)
        )
        // M: hour-angle frame -> horizontal Cartesian (East, Zenith, South).
        let m = simd_double3x3(
            SIMD3(0, cosLat, sinLat),
            SIMD3(-1, 0, 0),
            SIMD3(0, sinLat, -cosLat)
        )

        ofDateToHorizontal = m * h
        j2000ToHorizontal = ofDateToHorizontal * j2000ToTrueOfDate
        // A rotation commutes with normalise(v + a): rotating the aberration
        // vector into the horizontal frame once lets every star pay a single
        // matrix product.
        self.aberration = ofDateToHorizontal * aberration
        refractionEnabled = frameData.refractionEnabled

        centerDirection = CoordinateTransformService.unitDirection(
            fromHorizontal: frameData.cameraCenter
        )
        let basis = CoordinateTransformService.cameraBasis(centerDirection: centerDirection)
        right = basis.right
        up = basis.up

        edgeScale = CoordinateTransformService.projectionEdgeScale(
            fieldOfViewDegrees: frameData.cameraFieldOfViewDegrees
        )

        let size = frameData.viewportSize
        aspectScaleY = (size.width > 0 && size.height > 0)
            ? Double(size.width / size.height)
            : 1.0
    }

    // MARK: - Directions

    /// Horizontal-frame unit vector for a J2000 catalogue position.
    @inline(__always)
    func direction(j2000 equatorial: EquatorialCoordinate) -> SIMD3<Double> {
        direction(j2000Unit: Self.unitVector(equatorial))
    }

    /// Horizontal-frame unit vector for a J2000 catalogue position whose unit
    /// vector has already been computed (see `StarIndex.Sample`). Identical to
    /// `direction(j2000:)` minus the four trigonometric calls that turn RA/Dec
    /// into that vector.
    @inline(__always)
    func direction(j2000Unit v: SIMD3<Double>) -> SIMD3<Double> {
        // `simd_fast_normalize` rather than `simd_normalize`: it is accurate to
        // about one part in 10^7, which is a thousandth of an arcsecond of
        // direction, against an aberration term of 20 arcseconds and a pixel
        // worth 0.36 arcseconds at the narrowest field. The exact reciprocal
        // square root buys nothing here and this runs a few thousand times a
        // frame.
        apparent(simd_fast_normalize(j2000ToHorizontal * v + aberration))
    }

    /// Lifts a geometric horizontal direction by refraction, when enabled.
    @inline(__always)
    func apparent(_ d: SIMD3<Double>) -> SIMD3<Double> {
        refractionEnabled ? refraction.apparent(direction: d) : d
    }

    /// Horizontal-frame unit vector for a position already referred to the
    /// equinox of date (Sun, Moon, planets).
    @inline(__always)
    func direction(ofDate equatorial: EquatorialCoordinate) -> SIMD3<Double> {
        apparent(ofDateToHorizontal * Self.unitVector(equatorial))
    }

    /// Horizontal-frame unit vector for a *geometric* horizontal direction
    /// (satellites, sky paths), lifted by refraction.
    @inline(__always)
    func direction(geometricHorizontal d: SIMD3<Double>) -> SIMD3<Double> {
        apparent(d)
    }

    @inline(__always)
    static func unitVector(_ equatorial: EquatorialCoordinate) -> SIMD3<Double> {
        let ra = Angle.degreesToRadians(equatorial.rightAscensionDegrees)
        let dec = Angle.degreesToRadians(equatorial.declinationDegrees)
        let cosDec = cos(dec)
        return SIMD3(cosDec * cos(ra), cosDec * sin(ra), sin(dec))
    }

    /// Alt/az for a horizontal-frame direction. Deliberately separate from
    /// `project`: only the objects that actually land on screen need it.
    @inline(__always)
    func horizontal(direction d: SIMD3<Double>) -> HorizontalCoordinate {
        HorizontalCoordinate(
            altitudeDegrees: Angle.radiansToDegrees(asin(max(-1.0, min(1.0, d.y)))),
            azimuthDegrees: Angle.normalizeDegrees(
                Angle.radiansToDegrees(atan2(d.x, -d.z))
            )
        )
    }

    // MARK: - Projection

    /// Stereographic projection of a horizontal-frame direction to viewport
    /// NDC, or nil where the projection is not usable — the same rejections,
    /// in the same order, as `CoordinateTransformService.stereographicProject`
    /// followed by `aspectCorrected`.
    @inline(__always)
    func project(direction d: SIMD3<Double>) -> SIMD2<Double>? {
        let cosC = simd_dot(centerDirection, d)
        if cosC < -0.9999 { return nil }

        let k = 2.0 / (1.0 + cosC)
        guard k.isFinite, cosC > -0.999 else { return nil }
        guard edgeScale > 1e-6 else { return nil }

        let x = k * simd_dot(right, d) / edgeScale
        let y = k * simd_dot(up, d) / edgeScale

        if cosC < 0, (x * x + y * y) > 16 { return nil }

        return SIMD2(x, y * aspectScaleY)
    }

    /// Convenience for the few call sites that start from alt/az (satellites,
    /// compass points): the direction is already horizontal, so no rotation
    /// is involved.
    @inline(__always)
    func project(horizontal coordinate: HorizontalCoordinate, refract: Bool = true) -> SIMD2<Double>? {
        let d = CoordinateTransformService.unitDirection(fromHorizontal: coordinate)
        return project(direction: refract ? apparent(d) : d)
    }
}
