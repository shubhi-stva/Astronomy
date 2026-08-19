//
//  TopocentricTransform.swift
//  Astronomy
//
//  Alt/az for objects that are *near*, which is a genuinely different problem
//  from the one `CoordinateTransformService` solves.
//
//  Every other object in this app is treated as infinitely distant: a star's
//  RA/Dec is the same from anywhere on Earth, so the horizontal transform needs
//  only the observer's latitude and the sidereal time. A satellite is not like
//  that at all. The ISS is 400 km up; the Earth is 6,378 km across. Two people
//  a few hundred kilometres apart see it in completely different parts of the
//  sky, and for one of them it is below the horizon entirely. Parallax is not a
//  correction here, it is the dominant term.
//
//  So this file takes the honest route:
//
//      observer geocentric vector  ->  satellite geocentric vector
//                                  ->  topocentric range vector
//                                  ->  alt/az
//
//  The observer's position uses the WGS-84 *ellipsoid*, not a sphere. The
//  difference between the two is up to 21 km at mid-latitudes, which for a
//  400 km target is a couple of degrees of pointing — far too much to wave
//  away.
//
//  Frames. SGP4 emits TEME (True Equator, Mean Equinox of date). This code
//  rotates the observer into that frame with Greenwich Mean Sidereal Time,
//  which is the standard practice for TEME and is what the SGP4 literature
//  assumes. Strictly, TEME's origin of right ascension differs from the true
//  equinox by the equation of the equinoxes (up to about 1.1 seconds of time,
//  ~16 arcseconds), and using GMST rather than GAST absorbs exactly that
//  difference. For a satellite whose position is already uncertain by
//  kilometres from element-set age, an arcsecond-level frame subtlety is far
//  below the noise floor — but it is an approximation, and it is named here
//  rather than quietly ignored.
//

import Foundation
import simd

enum TopocentricTransform {

    // MARK: - WGS-84 ellipsoid

    /// Semi-major axis of the WGS-84 reference ellipsoid, in kilometres.
    static let earthEquatorialRadiusKm = 6378.137
    /// WGS-84 flattening.
    static let earthFlattening = 1.0 / 298.257223563
    /// First eccentricity squared, `2f - f^2`.
    static let earthEccentricitySquared = earthFlattening * (2.0 - earthFlattening)
    /// Mean radius, used only where a sphere is genuinely the right model
    /// (the shadow-cone test).
    static let earthMeanRadiusKm = 6371.0

    /// Observer's geocentric position in the TEME frame, in kilometres.
    ///
    /// The standard geodetic-to-geocentric reduction: `C` and `S` are the
    /// ellipsoid's radius-of-curvature factors, and the local sidereal time
    /// supplies the rotation of the observer's meridian into the inertial
    /// frame.
    ///
    /// - Parameter heightMetres: elevation above the ellipsoid. Defaults to
    ///   sea level; the app does not currently know the observer's altitude,
    ///   and at satellite distances a few hundred metres is negligible.
    static func observerPositionTEME(
        observer: GeographicLocation,
        julianDay: Double,
        heightMetres: Double = 0
    ) -> SIMD3<Double> {
        let latitude = Angle.degreesToRadians(observer.latitudeDegrees)
        let lst = Angle.degreesToRadians(
            CoordinateTransformService.localSiderealTimeDegrees(
                julianDay: julianDay, longitudeDegrees: observer.longitudeDegrees
            )
        )

        let sinLat = sin(latitude)
        let c = 1.0 / (1.0 - earthEccentricitySquared * sinLat * sinLat).squareRoot()
        let s = c * (1.0 - earthEccentricitySquared)
        let heightKm = heightMetres / 1000.0

        let equatorialDistance = (earthEquatorialRadiusKm * c + heightKm) * cos(latitude)
        return SIMD3(
            equatorialDistance * cos(lst),
            equatorialDistance * sin(lst),
            (earthEquatorialRadiusKm * s + heightKm) * sinLat
        )
    }

    // MARK: - Topocentric look angles

    /// One satellite as seen from one place at one moment.
    struct LookAngles: Hashable, Sendable {
        var horizontal: HorizontalCoordinate
        /// Distance from the observer to the satellite, in kilometres.
        var rangeKilometres: Double
        /// Height of the satellite above the WGS-84 ellipsoid's surface,
        /// in kilometres. Approximated as `|r| - R(geodetic latitude)`.
        var altitudeAboveGroundKm: Double
    }

    /// Converts a geocentric TEME position into the observer's horizontal
    /// frame.
    ///
    /// The range vector is resolved onto the topocentric south/east/zenith
    /// basis, which is the direct expression of "stand here, look up".
    static func lookAngles(
        satellitePositionTEME satellite: SIMD3<Double>,
        observer: GeographicLocation,
        julianDay: Double,
        heightMetres: Double = 0
    ) -> LookAngles {
        ObserverFrame(observer: observer, julianDay: julianDay, heightMetres: heightMetres)
            .lookAngles(satellitePositionTEME: satellite)
    }

    /// The observer's position and orientation at one instant, hoisted out of
    /// the per-satellite loop.
    ///
    /// Everything in here — the sidereal time polynomial, the ellipsoid
    /// radius, four trigonometric functions — depends only on where and when
    /// the observer is, not on which satellite is being looked at. Computing
    /// it inside `lookAngles` meant paying for all of it once per satellite
    /// per frame, several hundred times over, for an answer that was the same
    /// every time.
    struct ObserverFrame: Sendable {
        let positionTEME: SIMD3<Double>
        let sinLat: Double, cosLat: Double
        let sinLST: Double, cosLST: Double

        init(observer: GeographicLocation, julianDay: Double, heightMetres: Double = 0) {
            positionTEME = observerPositionTEME(
                observer: observer, julianDay: julianDay, heightMetres: heightMetres
            )
            let latitude = Angle.degreesToRadians(observer.latitudeDegrees)
            let lst = Angle.degreesToRadians(
                CoordinateTransformService.localSiderealTimeDegrees(
                    julianDay: julianDay, longitudeDegrees: observer.longitudeDegrees
                )
            )
            sinLat = sin(latitude); cosLat = cos(latitude)
            sinLST = sin(lst); cosLST = cos(lst)
        }

        /// The range vector resolved onto the south/east/zenith basis, plus
        /// its magnitude.
        @inline(__always)
        func southEastZenith(
            satellitePositionTEME satellite: SIMD3<Double>
        ) -> (south: Double, east: Double, zenith: Double, rangeKilometres: Double) {
            let range = satellite - positionTEME
            return (
                south: sinLat * cosLST * range.x + sinLat * sinLST * range.y - cosLat * range.z,
                east: -sinLST * range.x + cosLST * range.y,
                zenith: cosLat * cosLST * range.x + cosLat * sinLST * range.y + sinLat * range.z,
                rangeKilometres: simd_length(range)
            )
        }

        /// The satellite's direction as a unit vector in the app's horizontal
        /// Cartesian frame (X east, Y zenith, Z south) — the same frame
        /// `CoordinateTransformService.unitDirection` produces, and therefore
        /// directly projectable without ever forming alt/az.
        ///
        /// This is what lets the renderer reject an off-screen satellite
        /// before paying for an arcsine and an arctangent.
        @inline(__always)
        func horizontalDirection(
            satellitePositionTEME satellite: SIMD3<Double>
        ) -> (direction: SIMD3<Double>, rangeKilometres: Double) {
            let sez = southEastZenith(satellitePositionTEME: satellite)
            guard sez.rangeKilometres > 0 else { return (SIMD3(0, 1, 0), 0) }
            let inverse = 1.0 / sez.rangeKilometres
            return (
                SIMD3(sez.east * inverse, sez.zenith * inverse, sez.south * inverse),
                sez.rangeKilometres
            )
        }

        func lookAngles(satellitePositionTEME satellite: SIMD3<Double>) -> LookAngles {
            let sez = southEastZenith(satellitePositionTEME: satellite)
            let rangeMagnitude = sez.rangeKilometres
            let altitude = rangeMagnitude > 0
                ? Angle.radiansToDegrees(asin(max(-1.0, min(1.0, sez.zenith / rangeMagnitude))))
                : 0
            // Azimuth from north, increasing eastward — the same convention
            // `CoordinateTransformService.horizontal` establishes, so
            // satellites land in the same horizontal frame as everything else.
            let azimuth = Angle.normalizeDegrees(
                Angle.radiansToDegrees(atan2(sez.east, -sez.south))
            )
            return LookAngles(
                horizontal: HorizontalCoordinate(altitudeDegrees: altitude, azimuthDegrees: azimuth),
                rangeKilometres: rangeMagnitude,
                altitudeAboveGroundKm: heightAboveEllipsoid(geocentricPosition: satellite)
            )
        }
    }

    /// Height above the WGS-84 ellipsoid, in kilometres.
    ///
    /// Uses the closed-form radius of the ellipsoid at the point's *geocentric*
    /// latitude rather than iterating for the geodetic latitude. The two differ
    /// by at most about 100 metres of computed height — irrelevant next to the
    /// kilometres of along-track error a week-old element set carries, and this
    /// runs for every satellite on every propagation tick.
    static func heightAboveEllipsoid(geocentricPosition r: SIMD3<Double>) -> Double {
        let magnitude = simd_length(r)
        guard magnitude > 0 else { return 0 }
        let sinLat = r.z / magnitude
        let localRadius = earthEquatorialRadiusKm
            * (1.0 - earthFlattening * sinLat * sinLat)
        return magnitude - localRadius
    }

    // MARK: - Illumination

    /// Whether a satellite is in sunlight, and if not, how deeply shadowed.
    enum Illumination: Int, Hashable, Sendable {
        /// In full sunlight — the only state in which a satellite is actually
        /// visible from the ground.
        case sunlit = 0
        /// Partially shadowed: the Earth covers part of the Sun's disk as seen
        /// from the satellite. Real, brief, and worth distinguishing because it
        /// is what a satellite fading out at the shadow entry looks like.
        case penumbra = 1
        /// Fully in the Earth's shadow. Invisible from the ground.
        case umbra = 2

        var isSunlit: Bool { self == .sunlit }
    }

    /// Angular radius of the Sun as seen from Earth is not constant, but the
    /// shadow-cone half-angles vary by well under a percent over the year, so
    /// they are computed from mean values once.
    ///
    /// `sin(alpha_umbra) = (R_sun - R_earth) / d`, and
    /// `sin(alpha_penumbra) = (R_sun + R_earth) / d`.
    private static let sunRadiusKm = 696_000.0

    /// Conical shadow test (Vallado, *Fundamentals of Astrodynamics and
    /// Applications*, the umbral/penumbral cone geometry).
    ///
    /// A cylindrical test would be simpler, but it gets the terminator wrong by
    /// a noticeable margin for high orbits: the Earth's shadow is a cone that
    /// closes at about 1.4 million km, so at geostationary distance the umbra
    /// is already meaningfully narrower than the Earth. Since satellites
    /// entering and leaving shadow is the single most recognisable thing real
    /// satellites do, it is worth the extra dozen operations.
    ///
    /// - Parameters:
    ///   - satellite: geocentric satellite position, km, TEME.
    ///   - sunDirection: geocentric *unit* vector toward the Sun, same frame.
    ///   - sunDistanceKm: Earth-Sun distance.
    static func illumination(
        satellitePositionTEME satellite: SIMD3<Double>,
        sunDirection: SIMD3<Double>,
        sunDistanceKm: Double
    ) -> Illumination {
        // Sunward hemisphere: trivially lit, and the majority case.
        let alongSun = simd_dot(satellite, sunDirection)
        if alongSun >= 0 { return .sunlit }

        let earthRadius = earthMeanRadiusKm
        let sinUmbra = (sunRadiusKm - earthRadius) / sunDistanceKm
        let sinPenumbra = (sunRadiusKm + earthRadius) / sunDistanceKm
        let umbraAngle = asin(sinUmbra)
        let penumbraAngle = asin(sinPenumbra)

        // Resolve the satellite along the anti-sunward shadow axis.
        let horizontal = -alongSun                     // always positive here
        let vertical = simd_length(satellite - alongSun * sunDirection)

        let penumbraApexDistance = earthRadius / sinPenumbra
        let penumbraRadius = tan(penumbraAngle) * (penumbraApexDistance + horizontal)
        guard vertical <= penumbraRadius else { return .sunlit }

        let umbraApexDistance = earthRadius / sinUmbra
        let umbraRadius = tan(umbraAngle) * (umbraApexDistance - horizontal)
        return vertical <= umbraRadius ? .umbra : .penumbra
    }

    /// Geocentric unit vector toward the Sun in the equatorial frame of date,
    /// treated as TEME (see the frame note at the top of this file).
    static func sunDirection(equatorial: EquatorialCoordinate) -> SIMD3<Double> {
        let ra = Angle.degreesToRadians(equatorial.rightAscensionDegrees)
        let dec = Angle.degreesToRadians(equatorial.declinationDegrees)
        return SIMD3(cos(dec) * cos(ra), cos(dec) * sin(ra), sin(dec))
    }
}
