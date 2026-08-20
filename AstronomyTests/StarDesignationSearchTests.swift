//
//  StarDesignationSearchTests.swift
//  AstronomyTests
//
//  The regenerated star catalogue carries designations, and every star in it
//  is findable by one. Also covers the constellation search path, which shares
//  the same normalisation.
//
//  Synchronous throughout, and not `@MainActor`: a main-actor-isolated class
//  released inside a `@MainActor` XCTestCase crashes the test host.
//

import XCTest
@testable import Astronomy

final class StarDesignationSearchTests: XCTestCase {

    private static let bundledStars: [Star] = {
        let bundle = Bundle(for: StarDesignationSearchTests.self)
        let url = bundle.url(forResource: "stars", withExtension: "json")
            ?? Bundle.main.url(forResource: "stars", withExtension: "json")!
        return try! JSONDecoder().decode([Star].self, from: Data(contentsOf: url))
    }()

    private static let index = StarSearchIndex(stars: bundledStars)

    private func search(_ query: String) -> [Star] {
        Self.index.matches(query: query)
    }

    // MARK: - Catalogue integrity

    /// The regeneration only *added* fields. The star set, its ordering and
    /// every id must be untouched, because `constellations.json` joins on
    /// those ids.
    func testCatalogueIsUnchangedApartFromAddedDesignations() throws {
        let stars = Self.bundledStars
        XCTAssertEqual(stars.count, 83_479)

        // Still sorted brightest-first.
        XCTAssertEqual(stars.first?.name, "Sirius")
        for (a, b) in zip(stars, stars.dropFirst()) {
            XCTAssertLessThanOrEqual(a.magnitude, b.magnitude)
        }
        // The Sun's HYG row is still excluded.
        XCTAssertFalse(stars.contains { $0.id == 0 })
        // And nothing fainter than the export limit crept in.
        XCTAssertLessThanOrEqual(stars.last!.magnitude, 9.0)
    }

    func testEveryConstellationSegmentStillResolves() throws {
        let bundle = Bundle(for: StarDesignationSearchTests.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: "constellations", withExtension: "json")
                ?? Bundle.main.url(forResource: "constellations", withExtension: "json")
        )
        let segments = try JSONDecoder()
            .decode([ConstellationLineSegment].self, from: Data(contentsOf: url))
        XCTAssertEqual(segments.count, 690)

        let ids = Set(Self.bundledStars.map(\.id))
        for segment in segments {
            XCTAssertTrue(ids.contains(segment.starID1), "unresolved endpoint \(segment.starID1)")
            XCTAssertTrue(ids.contains(segment.starID2), "unresolved endpoint \(segment.starID2)")
        }
    }

    /// The whole point of the regeneration: essentially nothing is nameless
    /// any more. 431 stars had a proper name; every entry should now carry at
    /// least one designation something can be typed against.
    func testAlmostEveryStarNowCarriesADesignation() {
        let named = Self.bundledStars.filter { $0.name != nil }.count
        XCTAssertEqual(named, 431, "the proper-name set is unchanged")

        let withAnyDesignation = Self.bundledStars.filter {
            $0.name != nil || $0.hip != nil || $0.hd != nil || $0.hr != nil
                || $0.gliese != nil || $0.bayerFlamsteed != nil
        }.count
        XCTAssertGreaterThan(
            Double(withAnyDesignation) / Double(Self.bundledStars.count), 0.99,
            "over 99% of the catalogue should be addressable"
        )
    }

    // MARK: - Designation search

    func testEveryDesignationOfSiriusFindsSirius() {
        for query in ["Sirius", "HD 48915", "HIP 32349", "HR 2491", "Alpha Canis Majoris"] {
            XCTAssertEqual(search(query).first?.name, "Sirius", "query: \(query)")
        }
    }

    func testDesignationMatchingIsWhitespaceAndCaseInsensitive() {
        for query in ["HD48915", "hd 48915", "hd48915", "HD  48915", "hD 48915"] {
            XCTAssertEqual(search(query).first?.id, 32263, "query: \(query)")
        }
        XCTAssertEqual(search("alpha canis majoris").first?.name, "Sirius")
        XCTAssertEqual(search("ALPHACANISMAJORIS").first?.name, "Sirius")
    }

    func testBayerAndFlamsteedSpellingsAllWork() {
        // Betelgeuse is 58 Alpha Orionis, HR 2061, HD 39801, HIP 27989.
        for query in [
            "Betelgeuse", "Alp Ori", "alpha ori", "α Ori", "Alpha Orionis",
            "58 Orionis", "HR 2061", "HD39801", "HIP 27989",
        ] {
            XCTAssertEqual(search(query).first?.name, "Betelgeuse", "query: \(query)")
        }
    }

    func testGlieseDesignationsMatch() {
        // Sirius is Gl 244A in HYG.
        XCTAssertEqual(search("Gl 244A").first?.name, "Sirius")
        XCTAssertEqual(search("gliese244a").first?.name, "Sirius")
    }

    /// A bare number is tried against all three catalogues, so it still finds
    /// the star rather than silently doing nothing.
    func testBareCatalogueNumbersResolve() {
        XCTAssertTrue(search("32349").contains { $0.name == "Sirius" })
        XCTAssertTrue(search("48915").contains { $0.name == "Sirius" })
    }

    func testAStarWithNoProperNameIsStillFindable() {
        // Pick a nameless star that has a Henry Draper number and look it up.
        let star = try! XCTUnwrap(
            Self.bundledStars.first { $0.name == nil && $0.hd != nil && $0.magnitude > 7 }
        )
        let found = search("HD \(star.hd!)")
        XCTAssertEqual(found.first?.id, star.id)
        XCTAssertNotEqual(found.first?.displayName, "HR \(star.id)")
    }

    func testResultsAreBrightestFirstAndBounded() {
        let results = search("alpha")
        XCTAssertFalse(results.isEmpty)
        XCTAssertLessThanOrEqual(results.count, 20)
        for (a, b) in zip(results, results.dropFirst()) {
            XCTAssertLessThanOrEqual(a.magnitude, b.magnitude)
        }
    }

    func testASingleCharacterQueryDoesNotFloodTheResults() {
        XCTAssertTrue(search("a").isEmpty)
    }

    // MARK: - Display names

    /// The old fallback printed the HYG *row id* as an HR number. Sirius is
    /// row 32263 and HR 2491 — those are different catalogues, and conflating
    /// them was simply wrong.
    func testDisplayNamePrefersTheMostInformativeDesignation() {
        let sirius = Self.bundledStars.first { $0.name == "Sirius" }!
        XCTAssertEqual(sirius.displayName, "Sirius")
        XCTAssertNotEqual(sirius.id, sirius.hr)

        let bayerOnly = Star(
            id: 1, name: nil, ra: 0, dec: 0, magnitude: 3, colorIndex: nil,
            spectralType: nil, hip: 5, hd: 6, hr: 7, gliese: nil,
            bayerFlamsteed: "9Alp CMa"
        )
        XCTAssertEqual(bayerOnly.displayName, "α CMa")

        let hrOnly = Star(
            id: 2, name: nil, ra: 0, dec: 0, magnitude: 3, colorIndex: nil,
            spectralType: nil, hip: 5, hd: 6, hr: 7, gliese: nil, bayerFlamsteed: nil
        )
        XCTAssertEqual(hrOnly.displayName, "HR 7")

        let hdOnly = Star(
            id: 3, name: nil, ra: 0, dec: 0, magnitude: 3, colorIndex: nil,
            spectralType: nil, hip: 5, hd: 6, hr: nil, gliese: nil, bayerFlamsteed: nil
        )
        XCTAssertEqual(hdOnly.displayName, "HD 6")

        let hipOnly = Star(
            id: 4, name: nil, ra: 0, dec: 0, magnitude: 3, colorIndex: nil,
            spectralType: nil, hip: 5, hd: nil, hr: nil, gliese: nil, bayerFlamsteed: nil
        )
        XCTAssertEqual(hipOnly.displayName, "HIP 5")

        let nothing = Star(
            id: 4242, name: nil, ra: 0, dec: 0, magnitude: 3, colorIndex: nil,
            spectralType: nil, hip: nil, hd: nil, hr: nil, gliese: nil, bayerFlamsteed: nil
        )
        XCTAssertEqual(nothing.displayName, "HYG 4242", "the row id must be labelled as one")
    }

    func testBayerFlamsteedParsing() {
        let sirius = StarDesignations.parse(bayerFlamsteed: "9Alp CMa")
        XCTAssertEqual(sirius?.flamsteed, "9")
        XCTAssertEqual(sirius?.bayerCode, "Alp")
        XCTAssertNil(sirius?.bayerIndex)
        XCTAssertEqual(sirius?.constellation, "CMa")

        let split = StarDesignations.parse(bayerFlamsteed: "Alp-2 Cru")
        XCTAssertEqual(split?.bayerCode, "Alp")
        XCTAssertEqual(split?.bayerIndex, "2")
        XCTAssertEqual(StarDesignations.displayDesignation(bayerFlamsteed: "Alp-2 Cru"), "α² Cru")

        let flamsteedOnly = StarDesignations.parse(bayerFlamsteed: "61 Cyg")
        XCTAssertEqual(flamsteedOnly?.flamsteed, "61")
        XCTAssertNil(flamsteedOnly?.bayerCode)
        XCTAssertEqual(StarDesignations.displayDesignation(bayerFlamsteed: "61 Cyg"), "61 Cyg")

        XCTAssertNil(StarDesignations.parse(bayerFlamsteed: nil))
        XCTAssertNil(StarDesignations.parse(bayerFlamsteed: "nonsense"))
    }

    // MARK: - Constellations

    func testTheConstellationTableCoversTheBundledNames() throws {
        let bundle = Bundle(for: StarDesignationSearchTests.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: "constellation_names", withExtension: "json")
                ?? Bundle.main.url(forResource: "constellation_names", withExtension: "json")
        )
        let constellations = try JSONDecoder()
            .decode([Constellation].self, from: Data(contentsOf: url))
        XCTAssertEqual(constellations.count, 88)
        XCTAssertEqual(ConstellationDesignations.byAbbreviation.count, 88)

        for constellation in constellations {
            XCTAssertNotNil(
                ConstellationDesignations.abbreviationByLowercasedName[
                    constellation.name.lowercased()
                ],
                "no abbreviation for \(constellation.name)"
            )
        }
    }

    func testConstellationsMatchByNameAndAbbreviation() throws {
        let bundle = Bundle(for: StarDesignationSearchTests.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: "constellation_names", withExtension: "json")
                ?? Bundle.main.url(forResource: "constellation_names", withExtension: "json")
        )
        let constellations = try JSONDecoder()
            .decode([Constellation].self, from: Data(contentsOf: url))

        func best(_ query: String) -> String? {
            ConstellationDesignations
                .rankedMatches(query: query, in: constellations).first?.name
        }
        XCTAssertEqual(best("Orion"), "Orion")
        XCTAssertEqual(best("Ori"), "Orion")
        XCTAssertEqual(best("ori"), "Orion")
        XCTAssertEqual(best("Ursa Major"), "Ursa Major")
        XCTAssertEqual(best("ursamajor"), "Ursa Major")
        // "UMa" is also an interior substring of "TriangUlum AUstrale"; the
        // abbreviation has to outrank that.
        XCTAssertEqual(best("UMa"), "Ursa Major")
        XCTAssertEqual(best("uma"), "Ursa Major")
        XCTAssertEqual(best("UMi"), "Ursa Minor")
        // Diacritics fold, so Boötes is reachable from an ASCII keyboard.
        XCTAssertEqual(best("Bootes"), "Boötes")
        XCTAssertEqual(best("Boo"), "Boötes")
        XCTAssertNil(best("zzzz"))
        // A single character is not a query.
        XCTAssertNil(best("o"))
    }
}

