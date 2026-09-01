//
//  StarIndex.swift
//  Astronomy
//
//  A spatial index over the star catalogue, so a frame can touch only the
//  stars that could possibly be on screen.
//
//  Why this exists
//  ---------------
//  The catalogue is ~83,000 stars complete to magnitude 9. The old renderer
//  rejected faint stars with a magnitude compare and ran the full
//  equatorial -> horizontal -> stereographic chain on everything that
//  survived. That was fine when the deepest limit in force was 6.0 and the
//  catalogue stopped there. It is not fine now: at a dark sky and a narrow
//  field the limit reaches 9.0, and *every* star would pay for the trig,
//  every frame, while only a few hundred of them are anywhere near the
//  viewport.
//
//  The fix is a two-stage rejection:
//
//    1. Spatial. The sky is diced into an equatorial grid (RA x Dec cells).
//       Each cell is precomputed as a *bounding cone*: a unit direction and
//       an angular radius that provably contains every point in the cell.
//       The visible field is also a cone (centre direction + angular radius
//       covering the viewport corners). Two cones can only intersect if the
//       angle between their axes is at most the sum of their radii, which is
//       one dot product and one cosine-addition per cell — 2,592 of them,
//       microseconds.
//    2. Magnitude. Within a surviving cell the stars are stored sorted by
//       magnitude ascending, so the scan stops at the first star fainter than
//       the current limit instead of walking the cell's tail.
//
//  Correctness notes (the part that must not be wrong)
//  ---------------------------------------------------
//  * Everything is done with 3D unit vectors, never with RA/Dec intervals.
//    That removes both classic bugs for free: the RA = 0/360 wrap simply does
//    not exist in Cartesian space, and cells near the poles — where RA
//    converges and an interval test is badly misleading — are handled by the
//    same dot product as everything else.
//  * Each cell's bounding radius is measured by densely sampling the cell and
//    taking the maximum angle from the cell's centre direction, then padded.
//    Sampling can only *under*-estimate, so the padding (5% plus one degree)
//    is what makes the bound conservative; both are far larger than the
//    sub-arcminute error a 15x15 sampling of a 5-degree cell can produce.
//  * The test is conservative in one direction only: it may keep a cell that
//    turns out to be entirely off screen (harmless — `project` rejects those
//    stars a moment later), and it must never drop a cell that overlaps the
//    field. `StarIndexTests` checks that against a naive full scan at a range
//    of orientations, including both poles and the RA wrap.
//

import CoreGraphics
import Foundation
import simd

struct StarIndex {

    /// Grid resolution. 5-degree cells: 72 x 36 = 2,592 cells, averaging ~32
    /// stars each. Fine enough that a 3-degree field keeps only a handful of
    /// cells, coarse enough that the per-frame cell loop stays trivial.
    static let raCellCount = 72
    static let decCellCount = 36

    /// A cell's bounding cone plus the slice of `stars` it owns.
    struct Cell {
        /// Unit direction of the cone axis, in the equatorial Cartesian frame
        /// (X toward RA 0 on the equator, Z toward the north celestial pole).
        let axis: SIMD3<Double>
        /// Cone half-angle in radians, guaranteed to contain the whole cell.
        let radiusRadians: Double
        let cosRadius: Double
        let sinRadius: Double
        /// Half-open range into `stars`, magnitude-ascending.
        let start: Int
        let count: Int
    }

    /// The two fields the per-frame scan needs before it knows whether a star
    /// is worth looking at properly, in a form that costs nothing to touch.
    ///
    /// `Star` carries four optional `String`s (name, spectral type, Gliese,
    /// Bayer/Flamsteed), so every `stars[i]` in the frame loop is four retains
    /// and four releases — paid for the ~8,500 candidates a wide dark field
    /// hands over, of which only ~2,500 are ever drawn. This array is plain
    /// POD: the scan reads it, and only the survivors pay for the real `Star`.
    ///
    /// `direction` is the J2000 equatorial unit vector, which is a function of
    /// the catalogue position alone and so does not change from frame to
    /// frame. It is computed by exactly the expression `SkyProjector.unitVector`
    /// uses, so hoisting it here removes four trigonometric calls per candidate
    /// per frame without moving any star by a single bit.
    struct Sample {
        let direction: SIMD3<Double>
        let magnitude: Double
    }

    /// The catalogue, reordered so every cell's stars are contiguous.
    let stars: [Star]
    /// Parallel to `stars`, index for index.
    let samples: [Sample]
    let cells: [Cell]

    // MARK: - Construction

    /// Builds the index. Pure computation on value types, so it is safe (and
    /// intended) to run off the main actor — `CatalogService` does exactly
    /// that, immediately after decoding.
    init(stars input: [Star]) {
        let cellCount = Self.raCellCount * Self.decCellCount

        // Bucket by cell. The input catalogue is already sorted by magnitude
        // ascending, and appending preserves that order within each bucket, so
        // the per-cell magnitude sort is free.
        var buckets = [[Star]](repeating: [], count: cellCount)
        for star in input {
            buckets[Self.cellIndex(raDegrees: star.ra, decDegrees: star.dec)].append(star)
        }

        var flattened: [Star] = []
        flattened.reserveCapacity(input.count)
        var builtCells: [Cell] = []
        builtCells.reserveCapacity(cellCount)

        for decCell in 0..<Self.decCellCount {
            for raCell in 0..<Self.raCellCount {
                let index = decCell * Self.raCellCount + raCell
                let bucket = buckets[index]
                // Empty cells are dropped entirely: no bound to compute and
                // nothing for the per-frame loop to consider. Roughly a
                // quarter of the sky's cells are empty at this depth near the
                // poles, and skipping them is pure profit.
                guard !bucket.isEmpty else { continue }

                let bound = Self.boundingCone(raCell: raCell, decCell: decCell)
                builtCells.append(
                    Cell(
                        axis: bound.axis,
                        radiusRadians: bound.radius,
                        cosRadius: cos(bound.radius),
                        sinRadius: sin(bound.radius),
                        start: flattened.count,
                        count: bucket.count
                    )
                )
                flattened.append(contentsOf: bucket)
            }
        }

        self.stars = flattened
        self.cells = builtCells
        self.samples = flattened.map {
            Sample(
                direction: Self.direction(raDegrees: $0.ra, decDegrees: $0.dec),
                magnitude: $0.magnitude
            )
        }
    }

    /// Which cell a coordinate falls in. Clamped rather than trusted, so a
    /// dec of exactly +90 or an RA of exactly 360 cannot index out of bounds.
    static func cellIndex(raDegrees ra: Double, decDegrees dec: Double) -> Int {
        let normalizedRA = ((ra.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        let raCell = min(raCellCount - 1, max(0, Int(normalizedRA / (360.0 / Double(raCellCount)))))
        let decCell = min(
            decCellCount - 1,
            max(0, Int((dec + 90.0) / (180.0 / Double(decCellCount))))
        )
        return decCell * raCellCount + raCell
    }

    /// Unit vector in the equatorial Cartesian frame used throughout the app
    /// (see `SkyBackgroundUniforms.horizontalToEquatorial`).
    static func direction(raDegrees ra: Double, decDegrees dec: Double) -> SIMD3<Double> {
        let a = Angle.degreesToRadians(ra)
        let d = Angle.degreesToRadians(dec)
        let cosD = cos(d)
        return SIMD3(cosD * cos(a), cosD * sin(a), sin(d))
    }

    /// Bounding cone for one grid cell: axis at the cell's mid-direction,
    /// radius = worst sampled corner/edge/interior angle, padded.
    private static func boundingCone(raCell: Int, decCell: Int) -> (axis: SIMD3<Double>, radius: Double) {
        let raSpan = 360.0 / Double(raCellCount)
        let decSpan = 180.0 / Double(decCellCount)
        let ra0 = Double(raCell) * raSpan
        let dec0 = -90.0 + Double(decCell) * decSpan

        let axis = direction(raDegrees: ra0 + raSpan / 2, decDegrees: dec0 + decSpan / 2)

        // 15x15 samples over the cell: spacing well under half a degree, so
        // the sampled maximum is within arcminutes of the true one.
        let samples = 15
        var maxAngle = 0.0
        for i in 0...samples {
            let ra = ra0 + raSpan * Double(i) / Double(samples)
            for j in 0...samples {
                let dec = dec0 + decSpan * Double(j) / Double(samples)
                let dot = simd_dot(axis, direction(raDegrees: ra, decDegrees: dec))
                maxAngle = max(maxAngle, acos(max(-1.0, min(1.0, dot))))
            }
        }

        // Padding: 5% for sampling error plus a flat degree of slack. Cheap
        // insurance — an over-large cone costs a few extra projections, an
        // under-large one silently deletes stars.
        let padded = maxAngle * 1.05 + Angle.degreesToRadians(1.0)
        return (axis, min(.pi, padded))
    }

    // MARK: - Query

    /// Angular radius of the cone that contains the whole viewport, in
    /// radians, for a given field of view and aspect ratio.
    ///
    /// The stereographic projection maps an angular separation `c` from the
    /// camera centre to a tangent-plane radius of `2 * tan(c / 2)`; the
    /// renderer then divides by `projectionEdgeScale` to reach NDC. So the
    /// inverse of "furthest visible NDC radius" is exact, not an estimate:
    ///
    ///     R_ndc  = (1 + margin) * sqrt(1 + (height/width)^2)   // corner
    ///     R_proj = R_ndc * edgeScale
    ///     c      = 2 * atan(R_proj / 2)
    ///
    /// The `sqrt` term is the corner of the *aspect-corrected* frame: X spans
    /// the full horizontal FOV while Y is scaled by width/height, so in square
    /// projection space the vertical half-extent is `height/width`.
    static func fieldAngularRadiusRadians(
        fieldOfViewDegrees fov: Double,
        viewportSize: CGSize,
        marginNDC margin: Double = 0.2
    ) -> Double {
        let aspect: Double
        if viewportSize.width > 0, viewportSize.height > 0 {
            aspect = Double(viewportSize.height / viewportSize.width)
        } else {
            aspect = 1.0
        }
        let cornerNDC = (1.0 + margin) * (1.0 + aspect * aspect).squareRoot()
        let edgeScale = CoordinateTransformService.projectionEdgeScale(fieldOfViewDegrees: fov)
        let projectionRadius = cornerNDC * edgeScale
        let c = 2.0 * atan(projectionRadius / 2.0)
        // A further degree of slack, matching the padding philosophy above.
        return min(.pi, c + Angle.degreesToRadians(1.0))
    }

    /// Slices of `stars` belonging to cells whose bounding cone can intersect
    /// a field cone of half-angle `theta` about `centerDirection`.
    ///
    /// This is the single definition of the cull; both the renderer and the
    /// tests go through it, so they cannot drift apart.
    func visibleCellRanges(
        centerDirection: SIMD3<Double>,
        angularRadiusRadians theta: Double
    ) -> [Range<Int>] {
        let acceptAll = theta >= .pi - 1e-9
        let cosTheta = cos(theta)
        let sinTheta = sin(theta)

        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(64)
        for cell in cells {
            if !acceptAll {
                let sum = theta + cell.radiusRadians
                // sum >= pi means the two cones cover the sphere between them
                // and cannot fail to intersect.
                if sum < .pi {
                    // cos(theta + r), expanded so nothing in this loop needs a
                    // trig call: cells cache their own cos/sin.
                    let cosSum = cosTheta * cell.cosRadius - sinTheta * cell.sinRadius
                    if simd_dot(centerDirection, cell.axis) < cosSum { continue }
                }
            }
            ranges.append(cell.start..<(cell.start + cell.count))
        }
        return ranges
    }

    /// Visits every star that could plausibly be drawn: inside the field cone
    /// and brighter than the limit. Stars are visited in magnitude order
    /// within each cell, but not globally — the renderer does not care.
    func forEachCandidate(
        centerDirection: SIMD3<Double>,
        angularRadiusRadians theta: Double,
        magnitudeLimit: Double,
        _ body: (Star) -> Void
    ) {
        for range in visibleCellRanges(centerDirection: centerDirection, angularRadiusRadians: theta) {
            for i in range {
                let star = stars[i]
                // Cells are magnitude-ascending, so the first rejection ends
                // the cell.
                if star.magnitude >= magnitudeLimit { break }
                body(star)
            }
        }
    }

    /// Number of stars `forEachCandidate` would visit. Used by tests and
    /// useful for eyeballing the cull's effectiveness.
    func candidateCount(
        centerDirection: SIMD3<Double>,
        angularRadiusRadians theta: Double,
        magnitudeLimit: Double
    ) -> Int {
        var n = 0
        forEachCandidate(
            centerDirection: centerDirection,
            angularRadiusRadians: theta,
            magnitudeLimit: magnitudeLimit
        ) { _ in n += 1 }
        return n
    }
}
