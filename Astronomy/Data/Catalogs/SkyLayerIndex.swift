//
//  SkyLayerIndex.swift
//  Astronomy
//
//  Per-frame culling for the two layers that were still walking their whole
//  catalogue every frame: the deep-sky objects and the constellation figures.
//
//  `StarIndex` already does this for the 83,000 stars, and the measurement
//  that motivated it applies just as well here, one order of magnitude down.
//  Before this file, at a 3-degree field the geometry pass spent 0.166 ms on
//  909 deep-sky objects and 0.057 ms on 690 line segments — together *more
//  than the stars, the satellites and the planets combined* (0.044 ms), for
//  a field in which essentially none of them are on screen. The work was not
//  the drawing; it was deciding not to draw:
//
//   * every deep-sky object ran the full surface-brightness model (a log10, a
//     pow, two smoothsteps) before anything asked whether it was in frame;
//   * every line segment did two dictionary lookups into `starsByID` —
//     1,380 hash lookups per frame — before its endpoints were projected.
//
//  Both are replaced here by one dot product against the viewport cone, on a
//  unit vector computed once when the catalogue loads. The expensive part then
//  runs only for what survives, which at a narrow field is a handful of
//  objects and at a wide field is the whole catalogue either way.
//
//  The indices are built on `CatalogService`'s executor alongside the decode,
//  never on the main actor, and they are immutable values afterwards.
//

import CoreGraphics
import Foundation
import simd

/// Deep-sky objects with their J2000 unit vectors precomputed, ordered
/// magnitude-ascending so a scan can stop at the first object past the limit.
struct DeepSkyIndex: Sendable {

    /// The catalogue, magnitude-ascending.
    let objects: [DeepSkyObject]
    /// Parallel to `objects`: J2000 unit vector, index for index.
    let directions: [SIMD3<Double>]
    /// Parallel to `objects`: the object's angular *radius* in radians, so a
    /// large nebula whose centre is off-screen is still considered. M31's
    /// 3 degrees matters here; most entries are arcminutes.
    let radii: [Double]

    init(objects unsorted: [DeepSkyObject]) {
        let objects = unsorted.sorted { $0.magnitude < $1.magnitude }
        self.objects = objects
        directions = objects.map { StarIndex.direction(raDegrees: $0.ra, decDegrees: $0.dec) }
        radii = objects.map {
            Angle.degreesToRadians(($0.majorAxisArcmin ?? 0) / 60.0) * 0.5
        }
    }

    /// Indices of the objects whose extent can reach the viewport cone.
    ///
    /// One dot product each. The `acos` is avoided by comparing cosines, which
    /// is why the cone radius arrives as a cosine rather than an angle — at a
    /// wide field every object passes and the comparison is all that is paid.
    func visibleIndices(centerDirection: SIMD3<Double>, angularRadiusRadians theta: Double) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(min(objects.count, 256))
        for index in objects.indices {
            let separation = acos(max(-1.0, min(1.0, simd_dot(centerDirection, directions[index]))))
            if separation <= theta + radii[index] { result.append(index) }
        }
        return result
    }
}

/// Constellation figures with both endpoints resolved to J2000 unit vectors,
/// and a bounding cone per *constellation* so a figure that cannot be on
/// screen is skipped as a unit rather than segment by segment.
struct ConstellationFigureIndex: Sendable {

    /// One drawable segment: two J2000 unit vectors, already joined against
    /// the star catalogue.
    struct Segment: Sendable {
        let start: SIMD3<Double>
        let end: SIMD3<Double>
    }

    /// A run of segments that belong together spatially, with a bounding cone.
    ///
    /// The bundled `constellations.json` carries no constellation identity —
    /// only star-id pairs — so the grouping is spatial rather than nominal:
    /// segments are clustered by their own directions. That is all the cull
    /// needs, and it avoids inventing a join the data does not support.
    struct Group: Sendable {
        let segments: [Segment]
        let coneAxis: SIMD3<Double>
        let coneRadius: Double
    }

    let groups: [Group]
    /// Total segments that resolved, for the tests that pin the join.
    let segmentCount: Int

    init(segments rawSegments: [ConstellationLineSegment], starsByID: [Int: Star]) {
        var resolved: [Segment] = []
        resolved.reserveCapacity(rawSegments.count)
        for segment in rawSegments {
            guard let a = starsByID[segment.starID1], let b = starsByID[segment.starID2] else { continue }
            resolved.append(Segment(
                start: StarIndex.direction(raDegrees: a.ra, decDegrees: a.dec),
                end: StarIndex.direction(raDegrees: b.ra, decDegrees: b.dec)
            ))
        }
        segmentCount = resolved.count

        // Cluster into groups of roughly a constellation's size. A simple
        // greedy pass: each segment joins the first group whose axis is within
        // `groupRadius`, otherwise it starts one. Order-dependent and not
        // optimal, which does not matter — the cull is conservative either way,
        // and a slightly fat cone only means a few extra segments projected.
        let groupRadius = Angle.degreesToRadians(18.0)
        var axes: [SIMD3<Double>] = []
        var buckets: [[Segment]] = []
        for segment in resolved {
            let midpoint = simd_normalize(segment.start + segment.end)
            var placed = false
            for index in axes.indices {
                if simd_dot(axes[index], midpoint) >= cos(groupRadius) {
                    buckets[index].append(segment)
                    placed = true
                    break
                }
            }
            if !placed {
                axes.append(midpoint)
                buckets.append([segment])
            }
        }

        groups = buckets.indices.map { index in
            let segments = buckets[index]
            let sum = segments.reduce(SIMD3<Double>.zero) { $0 + $1.start + $1.end }
            let axis = simd_length(sum) > 1e-9 ? simd_normalize(sum) : axes[index]
            // Worst-case angle from the axis to either endpoint of any segment.
            var radius = 0.0
            for segment in segments {
                radius = max(radius, acos(max(-1.0, min(1.0, simd_dot(axis, segment.start)))))
                radius = max(radius, acos(max(-1.0, min(1.0, simd_dot(axis, segment.end)))))
            }
            return Group(segments: segments, coneAxis: axis, coneRadius: radius)
        }
    }
}
