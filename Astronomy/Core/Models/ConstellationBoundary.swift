//
//  ConstellationBoundary.swift
//  Astronomy
//
//  The official IAU constellation boundaries (Delporte, 1930), and the one
//  question they answer: *which constellation is this point in?*
//
//  WHAT THE BOUNDARIES ACTUALLY ARE
//
//  Delporte drew them as arcs of constant right ascension and constant
//  declination — but in the **B1875** frame, the equinox of the epoch he
//  worked in. That is why they look like a staircase today and why they are
//  not axis-aligned in J2000: precession has rotated the whole grid they were
//  ruled against by about two degrees since.
//
//  Keeping them in B1875 is therefore not an inconvenience to be converted
//  away, it is the definition. In that frame every edge is *exactly* a
//  straight line in (RA, Dec), so a point-in-region test is exact rather than
//  approximate, and the drawn curve is obtained by subdividing along the edge
//  in B1875 and rotating each sample forward. Converting the endpoints to
//  J2000 once and drawing straight lines between them would bow every long
//  edge away from the true boundary.
//
//  SOURCE
//
//  The 781 edges of the Stellarium project's "modern" sky culture
//  (`skycultures/modern/index.json`, `edges`), which in turn carries Pierre
//  Barbier's machine-readable reduction of Delporte's tables
//  (https://pbarbier.com/constellations/edges_18.txt), epoch B1875. Each edge
//  records its two endpoints and the two constellations it separates, which is
//  what makes the region test below possible without any polygon ordering.
//  See DATA_SOURCES.md.
//
//  WHY EDGES RATHER THAN POLYGONS
//
//  A previous attempt at this used CDS VI/49's `bound_20.dat`, a list of
//  boundary *vertices* sorted by right ascension. Grouping those by
//  constellation produces point sets in arbitrary order, not rings — the
//  polygons that came out were nonsense, and the region test built on them
//  reported gaps over most of the sky. Ray casting does not need ordered
//  rings at all; it needs the *set* of edges bounding a region. This file is
//  built around that fact, so there is no ordering to get wrong.
//

import Foundation
import simd

/// One boundary edge: a straight line in the B1875 (RA, Dec) plane,
/// separating two constellations.
struct ConstellationBoundaryEdge: Codable, Hashable, Sendable {

    enum CodingKeys: String, CodingKey {
        case kind = "t"
        case rightAscension1 = "r1", declination1 = "d1"
        case rightAscension2 = "r2", declination2 = "d2"
        case constellationA = "a", constellationB = "b"
    }

    /// "M" for a meridian (constant right ascension), "P" for a parallel
    /// (constant declination). Every edge is one or the other, which
    /// `ConstellationBoundaryTests` asserts against the bundled file.
    let kind: String
    /// Endpoints, B1875, degrees.
    let rightAscension1: Double, declination1: Double
    let rightAscension2: Double, declination2: Double
    /// The IAU abbreviations on either side, upper case ("ORI", "SER1").
    let constellationA: String, constellationB: String

    var isMeridian: Bool { kind == "M" }

    func touches(_ abbreviation: String) -> Bool {
        constellationA == abbreviation || constellationB == abbreviation
    }
}

/// The boundary set, with the frame conversions the rest of the app needs.
struct ConstellationBoundaries: Sendable {

    /// Besselian epoch B1875.0 as a Julian Date. B1900.0 is JD 2415020.31352
    /// and a Besselian year is 365.242198781 days, so B1875.0 is 25 of those
    /// earlier.
    static let b1875JulianDay = 2_415_020.31352 - 25 * 365.242198781

    let edges: [ConstellationBoundaryEdge]
    /// Edges indexed by the constellations they bound, so a region test walks
    /// tens of edges rather than all 781.
    private let edgesByConstellation: [String: [ConstellationBoundaryEdge]]
    /// J2000 -> B1875 rotation, for the region test.
    private let j2000ToB1875: simd_double3x3
    /// B1875 -> J2000, for drawing.
    let b1875ToJ2000: simd_double3x3

    /// Every IAU abbreviation present, as the source spells them (Serpens is
    /// "SER1" and "SER2").
    var abbreviations: [String] { edgesByConstellation.keys.sorted() }

    init(edges: [ConstellationBoundaryEdge]) {
        self.edges = edges
        var grouped: [String: [ConstellationBoundaryEdge]] = [:]
        for edge in edges {
            grouped[edge.constellationA, default: []].append(edge)
            grouped[edge.constellationB, default: []].append(edge)
        }
        edgesByConstellation = grouped
        let toB1875 = Precession.rotationMatrix(julianDay: Self.b1875JulianDay)
        j2000ToB1875 = toB1875
        b1875ToJ2000 = toB1875.transpose
    }

    // MARK: - Frames

    /// A J2000 position in the B1875 frame the boundaries are ruled in.
    func b1875(fromJ2000 equatorial: EquatorialCoordinate) -> EquatorialCoordinate {
        Precession.equatorial(fromVector: j2000ToB1875 * Precession.unitVector(equatorial))
    }

    /// A J2000 unit vector for a B1875 position, for drawing.
    func j2000Direction(b1875RightAscension ra: Double, declination dec: Double) -> SIMD3<Double> {
        b1875ToJ2000 * Precession.unitVector(
            EquatorialCoordinate(rightAscensionDegrees: ra, declinationDegrees: dec)
        )
    }

    // MARK: - Which constellation

    /// The constellation containing a **J2000** position, as the source
    /// spells it ("ORI", "SER1"), or nil if the tables are empty.
    func abbreviation(containing equatorial: EquatorialCoordinate) -> String? {
        let point = b1875(fromJ2000: equatorial)
        let ra = Angle.normalizeDegrees(point.rightAscensionDegrees)
        let dec = point.declinationDegrees
        for abbreviation in edgesByConstellation.keys {
            if contains(abbreviation: abbreviation, rightAscension: ra, declination: dec) {
                return abbreviation
            }
        }
        return nil
    }

    /// The IAU three-letter abbreviation in the app's casing ("Ori", "Ser"),
    /// for a J2000 position. Serpens's two halves both answer "Ser", which is
    /// the constellation's name.
    func constellation(containing equatorial: EquatorialCoordinate) -> String? {
        abbreviation(containing: equatorial).map(Self.displayAbbreviation)
    }

    /// The source spells its codes in upper case ("CMA", "UMI", "PSA", and
    /// "SER1"/"SER2" for the two halves of Serpens). The IAU's own spelling is
    /// mixed case and not derivable by a rule — "CMa", "UMi", "PsA" — so it is
    /// looked up in the normative table the rest of the app already uses
    /// (`ConstellationDesignations`) rather than capitalised by hand. That
    /// also means this and constellation search can never disagree about how a
    /// constellation is spelled.
    static func displayAbbreviation(_ raw: String) -> String {
        let base = String(raw.prefix(3)).lowercased()
        if let match = ConstellationDesignations.byAbbreviation.keys.first(
            where: { $0.lowercased() == base }
        ) {
            return match
        }
        return base.prefix(1).uppercased() + base.dropFirst()
    }

    /// The one region that encloses a celestial pole on the side the ray is
    /// cast toward.
    ///
    /// A property of the fixed IAU system (Delporte, 1930), not something
    /// discovered at runtime: Ursa Minor's region contains the north celestial
    /// pole and Octans's the south. It is named here rather than derived
    /// because deriving it needs the ordered rings this file deliberately does
    /// not build — and it is *checked* rather than trusted:
    /// `ConstellationBoundaryTests` asserts that every sampled direction on
    /// the sky falls in exactly one region, which fails immediately if this is
    /// wrong.
    static let northPoleRegion = "UMI"

    /// Ray casting along the meridian of the query point, over one region's
    /// edges: an odd number of crossings is inside. Everything is in B1875,
    /// where the edges are straight, so this is exact rather than approximate.
    ///
    /// Two details carry the whole correctness of it.
    ///
    /// **The seam.** Absolute right ascension is never used. Each endpoint is
    /// expressed as its offset *from the query meridian*, wrapped to ±180°, so
    /// the meridian sits at zero and "does this edge straddle it" is a sign
    /// change — a test that cannot be wrong at 0h. But a sign change in a
    /// ±180-wrapped offset happens at the *anti*-meridian too, so an edge whose
    /// endpoints are more than 180° apart in this frame is rejected: it
    /// straddles the far side of the sky, not the ray. Without that rejection
    /// Chamaeleon and Musca claim points in Tucana, half a sky away.
    ///
    /// **The pole.** For the region containing the pole the ray points at, the
    /// ray never leaves the region and the Jordan-curve argument collapses:
    /// an interior point counts zero crossings and reads as outside, while
    /// every exterior point also counts zero and — if the parity is simply
    /// inverted to compensate — reads as *inside*, so Ursa Minor swallows the
    /// sky. The fix is not a parity flip but a different ray: cast toward the
    /// *other* pole, where the region is bounded normally again.
    func contains(abbreviation: String, rightAscension ra: Double, declination dec: Double) -> Bool {
        guard let edges = edgesByConstellation[abbreviation] else { return false }
        // Northward for every region except the one wrapped around the north
        // pole, which is tested southward instead.
        let castsNorthward = abbreviation != Self.northPoleRegion
        var crossings = 0
        for edge in edges {
            let ua = Self.shortDelta(from: ra, to: edge.rightAscension1)
            let ub = Self.shortDelta(from: ra, to: edge.rightAscension2)
            // A meridian edge runs parallel to the ray and is never crossed.
            guard (ua <= 0 && ub > 0) || (ub <= 0 && ua > 0) else { continue }
            guard abs(ua - ub) < 180 else { continue }
            let t = ua / (ua - ub)
            let crossingDeclination = edge.declination1 + (edge.declination2 - edge.declination1) * t
            if castsNorthward ? (crossingDeclination > dec) : (crossingDeclination < dec) {
                crossings += 1
            }
        }
        return crossings % 2 == 1
    }

    static func shortDelta(from a: Double, to b: Double) -> Double {
        ((b - a + 540).truncatingRemainder(dividingBy: 360)) - 180
    }
}

/// The boundaries prepared for drawing: each edge subdivided along its own
/// B1875 straight line and rotated into J2000 unit vectors, with a bounding
/// cone so a frame can reject an edge with one dot product.
struct ConstellationBoundaryGeometry: Sendable {

    /// One drawable polyline.
    struct Edge: Sendable {
        /// J2000 unit vectors along the boundary, in order.
        let directions: [SIMD3<Double>]
        /// Bounding cone.
        let coneAxis: SIMD3<Double>
        let coneRadius: Double
    }

    let edges: [Edge]

    /// Sampling step along an edge, in degrees of the B1875 coordinate it
    /// varies in. Two degrees keeps the drawn curve smooth: the boundary is a
    /// straight line in B1875, so after the rotation to J2000 it bows by at
    /// most the precession angle over the edge's length, which is far under a
    /// pixel between samples this close.
    static let sampleStepDegrees: Double = 2.0

    init(boundaries: ConstellationBoundaries) {
        edges = boundaries.edges.map { edge in
            // Subdivide in whichever coordinate actually varies.
            let span = edge.isMeridian
                ? abs(edge.declination2 - edge.declination1)
                : abs(ConstellationBoundaries.shortDelta(
                    from: edge.rightAscension1, to: edge.rightAscension2
                  ))
            let steps = max(1, Int((span / Self.sampleStepDegrees).rounded(.up)))
            var directions: [SIMD3<Double>] = []
            directions.reserveCapacity(steps + 1)
            for step in 0...steps {
                let t = Double(step) / Double(steps)
                let dec = edge.declination1 + (edge.declination2 - edge.declination1) * t
                let ra = edge.rightAscension1 + ConstellationBoundaries.shortDelta(
                    from: edge.rightAscension1, to: edge.rightAscension2
                ) * t
                directions.append(
                    boundaries.j2000Direction(b1875RightAscension: ra, declination: dec)
                )
            }
            let sum = directions.reduce(SIMD3<Double>.zero, +)
            let axis = simd_length(sum) > 1e-9 ? simd_normalize(sum) : directions[0]
            let radius = directions.reduce(0.0) {
                max($0, acos(max(-1.0, min(1.0, simd_dot(axis, $1)))))
            }
            return Edge(directions: directions, coneAxis: axis, coneRadius: radius)
        }
    }
}
