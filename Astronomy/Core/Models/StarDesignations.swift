//
//  StarDesignations.swift
//  Astronomy
//
//  Unpacking the HYG catalogue's compact Bayer/Flamsteed field into the forms
//  a person actually types.
//
//  HYG stores one string per star — "9Alp CMa" — which is three facts glued
//  together: the Flamsteed number (9), the Bayer letter (Alpha, sometimes with
//  a superscript index as "Alp-1"), and the constellation abbreviation (Canis
//  Major). Nobody searches for "9Alp CMa". They search for "Alpha Canis
//  Majoris", or "alpha cma", or "α CMa", or "9 Canis Majoris". So the field is
//  parsed once and expanded into every one of those spellings.
//

import Foundation

enum StarDesignations {

    /// The three facts inside a HYG `bf` string.
    struct BayerFlamsteed {
        /// Flamsteed number, as printed ("9"). Nil when the star has none.
        let flamsteed: String?
        /// HYG's three-letter Bayer code ("Alp"), without any superscript.
        let bayerCode: String?
        /// The superscript index on a split Bayer letter: "1" for "Alp-1".
        let bayerIndex: String?
        /// IAU three-letter constellation abbreviation ("CMa").
        let constellation: String
    }

    /// Splits "9Alp-1 CMa" into its parts. Returns nil for anything that does
    /// not end in a constellation abbreviation, which is the one thing every
    /// well-formed designation has.
    static func parse(bayerFlamsteed raw: String?) -> BayerFlamsteed? {
        guard let raw, let separator = raw.lastIndex(of: " ") else { return nil }
        let constellation = String(raw[raw.index(after: separator)...])
        guard !constellation.isEmpty else { return nil }

        var head = Substring(raw[raw.startIndex..<separator])

        // Leading digits are the Flamsteed number.
        let digits = head.prefix { $0.isNumber }
        head = head.dropFirst(digits.count)
        let flamsteed = digits.isEmpty ? nil : String(digits)

        // What remains is the Bayer code, optionally "-<index>".
        var bayerCode: String?
        var bayerIndex: String?
        if !head.isEmpty {
            if let dash = head.firstIndex(of: "-") {
                bayerCode = String(head[head.startIndex..<dash])
                bayerIndex = String(head[head.index(after: dash)...])
            } else {
                bayerCode = String(head)
            }
        }

        return BayerFlamsteed(
            flamsteed: flamsteed, bayerCode: bayerCode,
            bayerIndex: bayerIndex, constellation: constellation
        )
    }

    /// The short form to put on a label: "α CMa", "α² Cru", "9 CMa".
    ///
    /// Bayer beats Flamsteed when a star has both, because that is how such a
    /// star is universally referred to — Betelgeuse's designation is
    /// "α Orionis", not "58 Orionis", even though HYG stores both.
    static func displayDesignation(bayerFlamsteed raw: String?) -> String? {
        guard let parts = parse(bayerFlamsteed: raw) else { return nil }
        if let code = parts.bayerCode, let letter = ConstellationDesignations.bayerLetters[code] {
            return "\(letter.symbol)\(superscript(parts.bayerIndex)) \(parts.constellation)"
        }
        if let flamsteed = parts.flamsteed {
            return "\(flamsteed) \(parts.constellation)"
        }
        return nil
    }

    /// Every spelling of a star's Bayer/Flamsteed designation that search
    /// should accept.
    static func searchAliases(bayerFlamsteed raw: String?) -> [String] {
        guard let raw, let parts = parse(bayerFlamsteed: raw) else { return [] }
        var aliases: [String] = [raw]

        let abbreviation = parts.constellation
        let genitive = ConstellationDesignations.byAbbreviation[abbreviation]?.genitive

        if let code = parts.bayerCode {
            let index = parts.bayerIndex.map { $0 } ?? ""
            let letter = ConstellationDesignations.bayerLetters[code]
            // "Alp" itself, the spelled-out "Alpha", and the character "α" —
            // all three get typed.
            for stem in [code, letter?.spelled, letter?.symbol].compactMap({ $0 }) {
                aliases.append("\(stem)\(index) \(abbreviation)")
                if let genitive { aliases.append("\(stem)\(index) \(genitive)") }
            }
        }
        if let flamsteed = parts.flamsteed {
            aliases.append("\(flamsteed) \(abbreviation)")
            if let genitive { aliases.append("\(flamsteed) \(genitive)") }
        }
        return aliases
    }

    private static func superscript(_ index: String?) -> String {
        guard let index else { return "" }
        let digits: [Character: Character] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
            "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        ]
        return String(index.map { digits[$0] ?? $0 })
    }
}
