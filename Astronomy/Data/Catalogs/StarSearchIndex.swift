//
//  StarSearchIndex.swift
//  Astronomy
//
//  Makes every star in the catalogue findable, not just the 431 with proper
//  names.
//
//  The catalogue is 83,479 stars and search runs on every keystroke, so a
//  linear scan over every designation of every star is not on. The index
//  splits the problem the way the data does:
//
//    * **Numbers** (HIP, HD, HR) are dense — 118k Hipparcos numbers, 99k
//      Henry Draper — and are always typed in full ("HD 48915"), never as a
//      substring. They get three hash maps and an O(1) lookup.
//    * **Text** (proper names, Bayer/Flamsteed, Gliese) is sparse — about
//      26,000 strings once every spelling is expanded — and *is* typed
//      partially. It gets a flat array and a substring scan, which at that
//      size is comfortably under a millisecond.
//
//  Everything is compared in a normalised form: lower-cased, diacritics
//  folded, and whitespace and hyphens removed, so "HD 48915", "hd48915" and
//  "HD-48915" are one query, matching the whitespace-insensitive rule the
//  deep-sky path already had.
//

import Foundation

struct StarSearchIndex {

    /// Normalised form used for every comparison in here.
    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .filter { !$0.isWhitespace && $0 != "-" }
    }

    private struct TextEntry {
        let key: String
        let starIndex: Int
    }

    private let stars: [Star]
    private let byHIP: [Int: Int]
    private let byHD: [Int: Int]
    private let byHR: [Int: Int]
    private let textEntries: [TextEntry]

    init(stars: [Star]) {
        self.stars = stars
        var hip: [Int: Int] = [:], hd: [Int: Int] = [:], hr: [Int: Int] = [:]
        hip.reserveCapacity(stars.count)
        hd.reserveCapacity(stars.count)
        var entries: [TextEntry] = []
        entries.reserveCapacity(30_000)

        for (index, star) in stars.enumerated() {
            // The catalogue is sorted brightest-first, so `min` keeps the
            // brighter component when a double shares a catalogue number.
            if let value = star.hip { hip[value] = min(hip[value] ?? index, index) }
            if let value = star.hd { hd[value] = min(hd[value] ?? index, index) }
            if let value = star.hr { hr[value] = min(hr[value] ?? index, index) }

            if let name = star.name, !name.isEmpty {
                entries.append(TextEntry(key: Self.normalize(name), starIndex: index))
            }
            for alias in StarDesignations.searchAliases(bayerFlamsteed: star.bayerFlamsteed) {
                entries.append(TextEntry(key: Self.normalize(alias), starIndex: index))
            }
            if let gliese = star.gliese, !gliese.isEmpty {
                entries.append(TextEntry(key: Self.normalize(gliese), starIndex: index))
                // "Gl 244A" is also written "Gliese 244A".
                if gliese.hasPrefix("Gl ") {
                    entries.append(
                        TextEntry(
                            key: Self.normalize("Gliese " + gliese.dropFirst(3)),
                            starIndex: index
                        )
                    )
                }
            }
        }

        self.byHIP = hip
        self.byHD = hd
        self.byHR = hr
        self.textEntries = entries
    }

    /// Stars matching `query`, brightest first, capped at `limit`.
    func matches(query: String, limit: Int = 20) -> [Star] {
        let condensed = Self.normalize(query)
        guard !condensed.isEmpty else { return [] }

        // Index -> true when the match was the whole designation rather than a
        // substring of it. Exact hits sort ahead of everything, so typing a
        // star's full name does not bury it under a brighter star that merely
        // contains it.
        var hits: [Int: Bool] = [:]

        for index in catalogNumberMatches(condensed) {
            hits[index] = true
        }

        // A single character matches an enormous slice of the alias table and
        // tells us nothing; two is the shortest query worth scanning.
        if condensed.count >= 2 {
            for entry in textEntries where entry.key.contains(condensed) {
                let isExact = entry.key == condensed
                hits[entry.starIndex] = (hits[entry.starIndex] ?? false) || isExact
                // Bounded work even for a query like "al" that matches
                // thousands: gather generously, then rank and cut.
                if hits.count >= limit * 20 { break }
            }
        }

        return hits
            .map { (star: stars[$0.key], isExact: $0.value) }
            .sorted { a, b in
                if a.isExact != b.isExact { return a.isExact }
                return a.star.magnitude < b.star.magnitude
            }
            .prefix(limit)
            .map(\.star)
    }

    /// Resolves "HD 48915" / "HIP32349" / "HR 2491", and a bare number against
    /// all three catalogues.
    ///
    /// A bare number is deliberately permissive: "32349" finding Sirius via
    /// its Hipparcos number is useful, and the alternative — silently ignoring
    /// a number the catalogue plainly contains — is not.
    private func catalogNumberMatches(_ condensed: String) -> [Int] {
        for (prefix, table) in [("hip", byHIP), ("hd", byHD), ("hr", byHR)] {
            guard condensed.hasPrefix(prefix) else { continue }
            guard let number = Int(condensed.dropFirst(prefix.count)),
                  let index = table[number] else { return [] }
            return [index]
        }
        guard let number = Int(condensed) else { return [] }
        return [byHIP[number], byHD[number], byHR[number]].compactMap { $0 }
    }
}
