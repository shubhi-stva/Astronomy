//
//  MoonPosition.swift
//  Astronomy
//
//  Low-precision geocentric position of the Moon using Meeus's truncated
//  series (a small subset of the ~60-term ELP2000-based series in Chapter
//  47 of "Astronomical Algorithms", 2nd ed.). Only the largest-amplitude
//  periodic terms are included, giving roughly 0.2-0.3 degree accuracy —
//  suitable for MVP visualization, not for occultation-grade prediction.
//

import Foundation

enum MoonPosition {

    static func equatorialCoordinate(julianDay jd: Double) -> EquatorialCoordinate {
        let t = JulianDate.julianCenturies(fromJulianDay: jd)

        // Moon's mean longitude (deg).
        let lPrime = Angle.normalizeDegrees(
            218.3164477 + 481267.88123421 * t - 0.0015786 * t * t + t * t * t / 538841.0
        )

        // Mean elongation of the Moon from the Sun (deg).
        let d = Angle.normalizeDegrees(
            297.8501921 + 445267.1114034 * t - 0.0018819 * t * t + t * t * t / 545868.0
        )

        // Sun's mean anomaly (deg).
        let m = Angle.normalizeDegrees(357.5291092 + 35999.0502909 * t - 0.0001536 * t * t)

        // Moon's mean anomaly (deg).
        let mPrime = Angle.normalizeDegrees(
            134.9633964 + 477198.8675055 * t + 0.0087414 * t * t + t * t * t / 69699.0
        )

        // Moon's argument of latitude (deg).
        let f = Angle.normalizeDegrees(
            93.2720950 + 483202.0175233 * t - 0.0036539 * t * t - t * t * t / 3526000.0
        )

        let dRad = Angle.degreesToRadians(d)
        let mRad = Angle.degreesToRadians(m)
        let mPrimeRad = Angle.degreesToRadians(mPrime)
        let fRad = Angle.degreesToRadians(f)

        // Dominant periodic terms for longitude (deg) and latitude (deg),
        // largest-amplitude subset of Meeus Table 47.a.
        var sigmaL = 0.0
        sigmaL += 6.288774 * sin(mPrimeRad)
        sigmaL += 1.274027 * sin(2 * dRad - mPrimeRad)
        sigmaL += 0.658314 * sin(2 * dRad)
        sigmaL += 0.213618 * sin(2 * mPrimeRad)
        sigmaL -= 0.185116 * sin(mRad)
        sigmaL -= 0.114332 * sin(2 * fRad)
        sigmaL += 0.058793 * sin(2 * dRad - 2 * mPrimeRad)
        sigmaL += 0.057066 * sin(2 * dRad - mRad - mPrimeRad)
        sigmaL += 0.053322 * sin(2 * dRad + mPrimeRad)
        sigmaL += 0.045758 * sin(2 * dRad - mRad)

        var sigmaB = 0.0
        sigmaB += 5.128122 * sin(fRad)
        sigmaB += 0.280602 * sin(mPrimeRad + fRad)
        sigmaB += 0.277693 * sin(mPrimeRad - fRad)
        sigmaB += 0.173237 * sin(2 * dRad - fRad)
        sigmaB += 0.055413 * sin(2 * dRad - mPrimeRad + fRad)
        sigmaB += 0.046271 * sin(2 * dRad - mPrimeRad - fRad)
        sigmaB += 0.032573 * sin(2 * dRad + fRad)

        let eclipticLongitude = lPrime + sigmaL
        let eclipticLatitude = sigmaB

        let t2 = t
        let meanObliquity = 23.439291 - 0.0130042 * t2 - 1.64e-7 * t2 * t2 + 5.04e-7 * t2 * t2 * t2

        let lambda = Angle.degreesToRadians(eclipticLongitude)
        let beta = Angle.degreesToRadians(eclipticLatitude)
        let epsilon = Angle.degreesToRadians(meanObliquity)

        let sinLambda = sin(lambda)
        let cosLambda = cos(lambda)
        let sinBeta = sin(beta)
        let cosBeta = cos(beta)
        let sinEps = sin(epsilon)
        let cosEps = cos(epsilon)

        let rightAscensionRad = atan2(
            sinLambda * cosEps - tan(beta) * sinEps,
            cosLambda
        )
        let declinationRad = asin(sinBeta * cosEps + cosBeta * sinEps * sinLambda)

        let ra = Angle.normalizeDegrees(Angle.radiansToDegrees(rightAscensionRad))
        let dec = Angle.radiansToDegrees(declinationRad)

        return EquatorialCoordinate(rightAscensionDegrees: ra, declinationDegrees: dec)
    }
}
