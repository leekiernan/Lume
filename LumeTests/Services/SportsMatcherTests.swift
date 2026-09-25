//
//  SportsMatcherTests.swift
//  LumeTests
//
//  Covers `SportsMatcher`'s token primitives — team tokenizing, aliases and
//  exonyms, normalization and whole-word containment. The scoring built on
//  them is `SportsChannelResolver`'s, covered in `SportsChannelResolverTests`.
//

import Foundation
@testable import Lume
import Testing

struct SportsMatcherTests {
    private let noAliases = SportsTeamAliases(rawEntries: [:])

    private func team(_ name: String, short: String? = nil, abbreviation: String = "") -> SportsTeam {
        SportsTeam(
            leagueId: "espn:soccer/eng.1",
            teamId: name,
            name: name,
            shortName: short ?? name,
            abbreviation: abbreviation
        )
    }

    // MARK: - Token extraction

    @Test func `tokens drop short affixes and fold diacritics`() {
        let tokens = SportsMatcher.tokens(for: team("FC Bayern München"), aliases: noAliases)
        #expect(tokens.contains("munchen"))
        #expect(tokens.contains("bayern"))
        #expect(!tokens.contains("fc"))
    }

    @Test func `a tennis player is matched on the surname alone`() {
        let player = SportsTeam(
            leagueId: "espn:tennis/wta", teamId: "10501", name: "Maria Timofeeva", shortName: "M. Timofeeva", abbreviation: ""
        )
        #expect(SportsMatcher.tokens(for: player, aliases: noAliases) == ["timofeeva"])
    }

    @Test func `tokens keep distinguishing words for same-city clubs`() {
        let real = SportsMatcher.tokens(for: team("Real Madrid"), aliases: noAliases)
        let atletico = SportsMatcher.tokens(for: team("Atlético Madrid"), aliases: noAliases)
        #expect(real.contains("real"))
        #expect(atletico.contains("atletico"))
        #expect(real != atletico)
    }

    @Test func `tokens include a three-letter abbreviation but not a two-letter one`() {
        let withAbbr = SportsMatcher.tokens(for: team("Tottenham", abbreviation: "TOT"), aliases: noAliases)
        #expect(withAbbr.contains("tot"))
        let shortAbbr = SportsMatcher.tokens(for: team("Juventus", abbreviation: "JV"), aliases: noAliases)
        #expect(!shortAbbr.contains("jv"))
    }

    // MARK: - Containment

    @Test func `containment matches whole words only`() {
        let haystack = SportsMatcher.normalize("Manchester City vs. Velocity FC")
        #expect(SportsMatcher.containsWord("city", in: haystack))
        #expect(!SportsMatcher.containsWord("loci", in: haystack))
        #expect(SportsMatcher.containsWord("velocity", in: haystack))
    }

    // MARK: - Aliases and exonyms

    @Test func `an exonym joins a team's tokens through the alias table`() {
        let aliases = SportsTeamAliases(rawEntries: ["Napoli": ["Neapel"]])
        #expect(SportsMatcher.tokens(for: team("Napoli"), aliases: aliases).contains("neapel"))
        #expect(!SportsMatcher.tokens(for: team("Napoli"), aliases: noAliases).contains("neapel"))
    }

    @Test func `a short-name alias joins the full club name's tokens`() {
        let aliases = SportsTeamAliases(rawEntries: ["Tottenham Hotspur": ["Spurs"]])
        #expect(SportsMatcher.tokens(for: team("Tottenham Hotspur"), aliases: aliases).contains("spurs"))
    }

    @Test func `alias lookup folds diacritics and case in its keys`() {
        let aliases = SportsTeamAliases(rawEntries: ["Atlético Madrid": ["Atleti"]])
        #expect(aliases.aliases(for: ["atletico madrid"]) == ["Atleti"])
    }

    // MARK: - Bundled table

    @Test func `the bundled alias table ships and resolves a known exonym`() {
        let bundled = SportsTeamAliases.bundled
        let napoli = bundled.aliases(for: ["Napoli"])
        #expect(napoli.contains { $0.localizedCaseInsensitiveContains("Neapel") })
    }
}
