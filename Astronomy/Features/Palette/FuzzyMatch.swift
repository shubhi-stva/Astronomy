//
//  FuzzyMatch.swift
//  Astronomy
//
//  Subsequence matching with a score, for the command palette.
//
//  The requirement a palette actually has is not "find every candidate that
//  contains these letters" — a substring test does that — it is "put the one
//  the user meant first after two or three keystrokes". So this is a scorer
//  first and a filter second, and every term in the score exists because of a
//  specific way the naive version gets it wrong:
//
//   * **"jup" must find Jupiter before it finds "Jump to midnight".** A match
//     that starts at the beginning of the candidate is worth far more than one
//     that starts in the middle, and a match whose characters are adjacent is
//     worth more than one scattered across the string.
//   * **"gj" must find "Go to Jupiter".** Matching a character that begins a
//     word is worth nearly as much as matching at the start, which is what
//     makes initials work without any special case for them.
//   * **"jupiter" must beat "jupiter's moons".** Shorter candidates win ties,
//     because the extra characters are unmatched noise.
//
//  Everything here is a pure function of two strings, which is what lets
//  `CommandPaletteTests` assert the ranking rather than eyeballing it.
//

import Foundation

enum FuzzyMatch {

    /// Score for a character matched at the very start of the candidate.
    static let leadingBonus = 12.0
    /// Score for a character matched at the start of a word.
    static let wordStartBonus = 8.0
    /// Score for a character matched immediately after the previous match.
    static let adjacencyBonus = 5.0
    /// Base score for any matched character.
    static let matchScore = 2.0
    /// Deducted per candidate character that is not part of the match, so a
    /// tight match in a short string beats a loose one in a long string.
    static let unmatchedPenalty = 0.15
    /// Deducted per character skipped between two matched characters.
    ///
    /// Without this, a subsequence spread across a whole sentence collects the
    /// same per-character credit as a tight one and can outscore it on length
    /// alone.
    static let gapPenalty = 0.4
    /// Awarded when the query appears in the candidate *contiguously*.
    ///
    /// This is the term that fixes the failure mode a pure subsequence scorer
    /// always has: "tonight" is scattered through "Turn on night vision"
    /// (t‑o‑n‑i‑g‑h‑t, all present, all in order) and would otherwise beat
    /// "Jump to tonight", where it is the actual word. An exact run is a far
    /// stronger signal of intent than a scattered one, and it is worth saying
    /// so explicitly rather than hoping the per-character terms add up right.
    static let substringBonus = 20.0
    /// Added on top when that contiguous run also starts a word.
    static let substringWordStartBonus = 10.0

    /// Matches `query` against `candidate`, case- and whitespace-insensitively.
    ///
    /// Returns nil when the query is not a subsequence of the candidate — which
    /// is the filter — and a score otherwise, higher being better. An empty
    /// query matches everything at zero, so a freshly-opened palette shows its
    /// commands in their declared order rather than in an arbitrary one.
    static func score(query: String, candidate: String) -> Double? {
        let queryCharacters = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !queryCharacters.isEmpty else { return 0 }
        let candidateCharacters = Array(candidate.lowercased())
        guard queryCharacters.count <= candidateCharacters.count else { return nil }

        var total = 0.0
        var queryIndex = 0
        var previousMatchIndex = -2

        for (index, character) in candidateCharacters.enumerated() {
            guard queryIndex < queryCharacters.count else { break }
            guard character == queryCharacters[queryIndex] else { continue }

            var score = matchScore
            if index == 0 {
                score += leadingBonus
            } else if isWordBoundary(candidateCharacters, index) {
                score += wordStartBonus
            }
            if index == previousMatchIndex + 1 {
                score += adjacencyBonus
            } else if previousMatchIndex >= 0 {
                score -= Double(index - previousMatchIndex - 1) * gapPenalty
            }
            total += score
            previousMatchIndex = index
            queryIndex += 1
        }

        guard queryIndex == queryCharacters.count else { return nil }
        total -= Double(candidateCharacters.count - queryCharacters.count) * unmatchedPenalty
        if let run = contiguousRun(queryCharacters, in: candidateCharacters) {
            total += substringBonus
            if isWordBoundary(candidateCharacters, run) { total += substringWordStartBonus }
        }
        return total
    }

    /// Index at which `query` occurs contiguously in `candidate`, if it does.
    private static func contiguousRun(
        _ query: [Character], in candidate: [Character]
    ) -> Int? {
        guard query.count <= candidate.count else { return nil }
        let last = candidate.count - query.count
        for start in 0...last {
            var matched = true
            for offset in query.indices where candidate[start + offset] != query[offset] {
                matched = false
                break
            }
            if matched { return start }
        }
        return nil
    }

    /// True when the character at `index` begins a word — i.e. the one before
    /// it is a separator, or the run changes from lower case to upper case,
    /// which is what makes "sd" find "ShowDeepSky"-style names as well as
    /// "Show deep sky".
    private static func isWordBoundary(_ characters: [Character], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        return !previous.isLetter && !previous.isNumber
    }

    /// Best score over a candidate and its aliases, or nil if none matched.
    ///
    /// Aliases are scored at a discount so a hit on the visible title always
    /// outranks a hit on a hidden keyword — otherwise a command whose keywords
    /// happened to match would jump above the command actually named.
    static let aliasDiscount = 0.6

    /// ...with one exception: an alias the query matches *in its entirety*.
    ///
    /// A partial hit on a hidden keyword is weak evidence, which is what the
    /// discount is for. A query that **is** the keyword is the strongest signal
    /// there is, and discounting it produces a specific, reproducible wrong
    /// answer: once a second grid layer existed, "grid" ranked the horizon grid
    /// above the equatorial one — not because it matched better, but because
    /// "Show the horizon grid" is three characters shorter than "Show the
    /// equatorial grid", so its title hit beat the exact keyword "grid" the
    /// equatorial grid declares. Length is a reasonable tie-break between two
    /// equally good matches and a terrible way to resolve "the user typed this
    /// command's own keyword".
    static func isCompleteMatch(query: String, alias: String) -> Bool {
        func normalise(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }
        return !alias.isEmpty && normalise(query) == normalise(alias)
    }

    static func bestScore(query: String, title: String, aliases: [String]) -> Double? {
        var best = score(query: query, candidate: title)
        for alias in aliases {
            guard let aliasScore = score(query: query, candidate: alias) else { continue }
            let weighted = isCompleteMatch(query: query, alias: alias)
                ? aliasScore
                : aliasScore * aliasDiscount
            if best == nil || weighted > best! { best = weighted }
        }
        return best
    }
}
