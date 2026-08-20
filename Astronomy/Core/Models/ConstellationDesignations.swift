//
//  ConstellationDesignations.swift
//  Astronomy
//
//  The IAU's 88 constellations, with the two other names each one answers to:
//  its three-letter abbreviation (the form the HYG catalogue's `con` column
//  and every Bayer designation uses — "Ori", "UMa", "CMa") and its Latin
//  genitive (the form a Bayer designation is *read* in — "Alpha Canis
//  Majoris", not "Alpha Canis Major").
//
//  Source: IAU list of constellations
//  (https://www.iau.org/public/themes/constellations/), which is the
//  normative table for all three columns. See DATA_SOURCES.md.
//
//  This table is what lets search answer "Ori" as well as "Orion", and what
//  lets a star with no proper name still be found by "Alpha Canis Majoris".
//

import Foundation

enum ConstellationDesignations {

    /// abbreviation -> (nominative, genitive).
    static let byAbbreviation: [String: (name: String, genitive: String)] = [
        "And": ("Andromeda", "Andromedae"),
        "Ant": ("Antlia", "Antliae"),
        "Aps": ("Apus", "Apodis"),
        "Aqr": ("Aquarius", "Aquarii"),
        "Aql": ("Aquila", "Aquilae"),
        "Ara": ("Ara", "Arae"),
        "Ari": ("Aries", "Arietis"),
        "Aur": ("Auriga", "Aurigae"),
        // Spelled with the diaeresis to match `constellation_names.json`;
        // search folds diacritics, so "Bootes" finds it too.
        "Boo": ("Boötes", "Boötis"),
        "Cae": ("Caelum", "Caeli"),
        "Cam": ("Camelopardalis", "Camelopardalis"),
        "Cnc": ("Cancer", "Cancri"),
        "CVn": ("Canes Venatici", "Canum Venaticorum"),
        "CMa": ("Canis Major", "Canis Majoris"),
        "CMi": ("Canis Minor", "Canis Minoris"),
        "Cap": ("Capricornus", "Capricorni"),
        "Car": ("Carina", "Carinae"),
        "Cas": ("Cassiopeia", "Cassiopeiae"),
        "Cen": ("Centaurus", "Centauri"),
        "Cep": ("Cepheus", "Cephei"),
        "Cet": ("Cetus", "Ceti"),
        "Cha": ("Chamaeleon", "Chamaeleontis"),
        "Cir": ("Circinus", "Circini"),
        "Col": ("Columba", "Columbae"),
        "Com": ("Coma Berenices", "Comae Berenices"),
        "CrA": ("Corona Australis", "Coronae Australis"),
        "CrB": ("Corona Borealis", "Coronae Borealis"),
        "Crv": ("Corvus", "Corvi"),
        "Crt": ("Crater", "Crateris"),
        "Cru": ("Crux", "Crucis"),
        "Cyg": ("Cygnus", "Cygni"),
        "Del": ("Delphinus", "Delphini"),
        "Dor": ("Dorado", "Doradus"),
        "Dra": ("Draco", "Draconis"),
        "Equ": ("Equuleus", "Equulei"),
        "Eri": ("Eridanus", "Eridani"),
        "For": ("Fornax", "Fornacis"),
        "Gem": ("Gemini", "Geminorum"),
        "Gru": ("Grus", "Gruis"),
        "Her": ("Hercules", "Herculis"),
        "Hor": ("Horologium", "Horologii"),
        "Hya": ("Hydra", "Hydrae"),
        "Hyi": ("Hydrus", "Hydri"),
        "Ind": ("Indus", "Indi"),
        "Lac": ("Lacerta", "Lacertae"),
        "Leo": ("Leo", "Leonis"),
        "LMi": ("Leo Minor", "Leonis Minoris"),
        "Lep": ("Lepus", "Leporis"),
        "Lib": ("Libra", "Librae"),
        "Lup": ("Lupus", "Lupi"),
        "Lyn": ("Lynx", "Lyncis"),
        "Lyr": ("Lyra", "Lyrae"),
        "Men": ("Mensa", "Mensae"),
        "Mic": ("Microscopium", "Microscopii"),
        "Mon": ("Monoceros", "Monocerotis"),
        "Mus": ("Musca", "Muscae"),
        "Nor": ("Norma", "Normae"),
        "Oct": ("Octans", "Octantis"),
        "Oph": ("Ophiuchus", "Ophiuchi"),
        "Ori": ("Orion", "Orionis"),
        "Pav": ("Pavo", "Pavonis"),
        "Peg": ("Pegasus", "Pegasi"),
        "Per": ("Perseus", "Persei"),
        "Phe": ("Phoenix", "Phoenicis"),
        "Pic": ("Pictor", "Pictoris"),
        "Psc": ("Pisces", "Piscium"),
        "PsA": ("Piscis Austrinus", "Piscis Austrini"),
        "Pup": ("Puppis", "Puppis"),
        "Pyx": ("Pyxis", "Pyxidis"),
        "Ret": ("Reticulum", "Reticuli"),
        "Sge": ("Sagitta", "Sagittae"),
        "Sgr": ("Sagittarius", "Sagittarii"),
        "Sco": ("Scorpius", "Scorpii"),
        "Scl": ("Sculptor", "Sculptoris"),
        "Sct": ("Scutum", "Scuti"),
        "Ser": ("Serpens", "Serpentis"),
        "Sex": ("Sextans", "Sextantis"),
        "Tau": ("Taurus", "Tauri"),
        "Tel": ("Telescopium", "Telescopii"),
        "Tri": ("Triangulum", "Trianguli"),
        "TrA": ("Triangulum Australe", "Trianguli Australis"),
        "Tuc": ("Tucana", "Tucanae"),
        "UMa": ("Ursa Major", "Ursae Majoris"),
        "UMi": ("Ursa Minor", "Ursae Minoris"),
        "Vel": ("Vela", "Velorum"),
        "Vir": ("Virgo", "Virginis"),
        "Vol": ("Volans", "Volantis"),
        "Vul": ("Vulpecula", "Vulpeculae"),
    ]

    /// Lower-cased nominative -> abbreviation, so a constellation found by
    /// name in `constellation_names.json` can be given its abbreviation back.
    static let abbreviationByLowercasedName: [String: String] = {
        var map: [String: String] = [:]
        for (abbreviation, names) in byAbbreviation {
            map[names.name.lowercased()] = abbreviation
        }
        return map
    }()

    /// Constellations matching `query`, best match first.
    ///
    /// Two forms are accepted: the name, matched as a substring, and the
    /// three-letter IAU abbreviation, matched only as a whole. Both go through
    /// `StarSearchIndex.normalize`, so case, spacing and diacritics are all
    /// irrelevant ("uma", "Ursa Major", "bootes" for Boötes).
    ///
    /// Ranking matters more here than the count does. "UMa" is a substring of
    /// "TriangUlum AUstrale" as well as being the abbreviation for Ursa Major,
    /// and a plain substring filter offers them in alphabetical order — which
    /// puts the wrong one first. Whole-name and abbreviation hits rank above
    /// prefixes, which rank above interior substrings.
    static func rankedMatches(query: String, in constellations: [Constellation]) -> [Constellation] {
        let condensed = StarSearchIndex.normalize(query)
        // One or two characters would match a dozen names as substrings; the
        // abbreviation path still needs three, so this costs nothing real.
        guard condensed.count >= 2 else { return [] }

        return constellations.compactMap { constellation -> (Constellation, Int)? in
            let name = StarSearchIndex.normalize(constellation.name)
            let abbreviation = abbreviationByLowercasedName[constellation.name.lowercased()]
                .map { StarSearchIndex.normalize($0) }
            if name == condensed || abbreviation == condensed { return (constellation, 0) }
            if name.hasPrefix(condensed) { return (constellation, 1) }
            if name.contains(condensed) { return (constellation, 2) }
            return nil
        }
        .sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            return a.0.name < b.0.name
        }
        .map(\.0)
    }

    /// The Bayer letters, in HYG's three-letter form, mapped to the Greek
    /// character and the spelled-out English name. A designation is written
    /// with the character ("α CMa") and spoken with the name ("Alpha Canis
    /// Majoris"), and search has to accept both.
    static let bayerLetters: [String: (symbol: String, spelled: String)] = [
        "Alp": ("α", "Alpha"), "Bet": ("β", "Beta"), "Gam": ("γ", "Gamma"),
        "Del": ("δ", "Delta"), "Eps": ("ε", "Epsilon"), "Zet": ("ζ", "Zeta"),
        "Eta": ("η", "Eta"), "The": ("θ", "Theta"), "Iot": ("ι", "Iota"),
        "Kap": ("κ", "Kappa"), "Lam": ("λ", "Lambda"), "Mu": ("μ", "Mu"),
        "Nu": ("ν", "Nu"), "Xi": ("ξ", "Xi"), "Omi": ("ο", "Omicron"),
        "Pi": ("π", "Pi"), "Rho": ("ρ", "Rho"), "Sig": ("σ", "Sigma"),
        "Tau": ("τ", "Tau"), "Ups": ("υ", "Upsilon"), "Phi": ("φ", "Phi"),
        "Chi": ("χ", "Chi"), "Psi": ("ψ", "Psi"), "Ome": ("ω", "Omega"),
    ]
}
