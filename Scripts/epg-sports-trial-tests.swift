import Foundation

/// Standalone regression checks: compile instead of epg-enrichment-trial.swift
/// with the same production sources. Throws on failure even in optimized builds.
@main
struct EPGSportsTrialTests {
    private struct Failure: Error { let name: String }
    private typealias TestCase = (String, ParsedProgramme, ParsedProgramme, EPGSportsProgrammeIdentity.Kind)

    @MainActor static func main() throws {
        let aliases = SportsTeamAliases(rawEntries: [
            "West Ham United": ["West Ham"], "Manchester United": ["Man Utd", "United"],
            "Manchester City": ["Man City", "City"]
        ])
        let cases = studioCases + fixtureCases
        for (name, provider, external, kind) in cases {
            let actual = EPGSportsProgrammeIdentity.compare(provider, external, aliases: aliases)
            guard actual.kind == kind else { throw Failure(name: "\(name): expected \(kind), got \(actual)") }
        }
        try checkReports(aliases)
        print("Passed \(cases.count + 6) offline sports identity/report checks; publication disabled.")
    }

    private static var studioCases: [TestCase] {
        [
            ("strict", row("Football"), row("Football"), .strict),
            ("studio episode", row("Good Morning Football : Episode 202 ᴸᶦᵛᵉ"), row("Good Morning Football"), .studio),
            ("studio casing", row("NFL GameDay : Episode 25"), row("NFL Gameday"), .studio),
            ("studio matchday", row("Inside Serie A : Matchday 6"), row("Inside Serie A"), .studio),
            ("unknown studio", row("Sports Chat : Episode 2"), row("Sports Chat"), .unresolved),
            ("unknown suffix", row("Good Morning Football : Special"), row("Good Morning Football"), .unresolved),
            ("episode conflict", row("TNT Sports Reload : Episode 40"), row("TNT Sports Reload", description: "E41"), .conflict),
            ("season conflict", row("TNT Sports Reload : Episode 40", description: "S26 E40"), row("TNT Sports Reload", description: "S25 E40"), .conflict),
            ("compact season conflict", row("TNT Sports Reload : Episode 40", description: "S26E40"), row("TNT Sports Reload", description: "S25E40"), .conflict),
            ("compact episode conflict", row("TNT Sports Reload : Episode 40"), row("TNT Sports Reload", description: "S26E41"), .conflict),
            ("matchday conflict", row("Inside Serie A : Matchday 6"), row("Inside Serie A : Matchday 7"), .conflict),
            ("live replay", row("Good Morning Football ᴸᶦᵛᵉ"), row("Good Morning Football", description: "Highlights"), .conflict),
            ("internal live replay", row("Good Morning Football ᴸᶦᵛᵉ", description: "Replay"), row("Good Morning Football"), .conflict),
            ("year conflict", row("Good Morning Football : Episode 2", description: "2025"), row("Good Morning Football", description: "2026"), .conflict),
            ("wrong interval", row("Good Morning Football", offset: 1), row("Good Morning Football"), .unresolved),
            ("empty interval", row("Football", duration: 0), row("Football", duration: 0), .unresolved),
            ("different programmes same time", row("MotoGP Films : Fabio Quartararo"), row("UIM F1H2O World Championship Highlights"), .unresolved)
        ]
    }

    private static var fixtureCases: [TestCase] {
        [
            ("season and reviewed alias", row("EFL Play-Off Classics : Blackpool v West Ham", description: "2011-12 Championship final"),
             row("EFL Greatest Games", subtitle: "West Ham United v Blackpool in the 2011/12 Championship final"), .teams),
            ("season final year", row("EFL : Blackpool v West Ham", description: "2010 Championship final"),
             row("EFL Greatest Games", subtitle: "West Ham United v Blackpool", description: "2009/10 Championship final"), .teams),
            ("explicit live pair", row("Premier League : Man Utd v Man City ᴸᶦᵛᵉ"), row("Live Premier League", subtitle: "Manchester City v Manchester United"), .teams),
            ("generic aliases rejected", row("Premier League : United v City ᴸᶦᵛᵉ"), row("Live Premier League", subtitle: "Manchester United v Manchester City"), .conflict),
            ("different pair", row("Premier League : Arsenal v Chelsea ᴸᶦᵛᵉ"), row("Live Premier League", subtitle: "Arsenal v Liverpool"), .conflict),
            ("gender names retained", row("Premier League : Arsenal Women v Chelsea Women ᴸᶦᵛᵉ"), row("Live Premier League", subtitle: "Arsenal v Chelsea"), .conflict),
            ("description alone insufficient", row("Premier League", description: "Arsenal v Chelsea 2026"), row("Live Premier League", description: "Arsenal v Chelsea 2026"), .unresolved),
            ("competition required", row("Arsenal v Chelsea ᴸᶦᵛᵉ"), row("Live Football", subtitle: "Arsenal v Chelsea"), .unresolved),
            ("competition conflict", row("Premier League : Arsenal v Chelsea ᴸᶦᵛᵉ"), row("Live Champions League", subtitle: "Arsenal v Chelsea"), .conflict),
            ("live absence insufficient", row("Premier League : Arsenal v Chelsea ᴸᶦᵛᵉ"), row("Premier League", subtitle: "Arsenal v Chelsea"), .unresolved),
            ("replay year required", row("EFL : Blackpool v West Ham"), row("EFL Greatest Games", subtitle: "West Ham United v Blackpool"), .unresolved),
            ("round conflict", row("International T20 : India v West Indies ᴸᶦᵛᵉ", description: "2nd T20"),
             row("Live International T20", subtitle: "India v West Indies", description: "third T20"), .conflict),
            ("round corroborated", row("International T20 : India v West Indies ᴸᶦᵛᵉ", description: "2nd T20"),
             row("Live International T20", subtitle: "India v West Indies", description: "second T20"), .teams),
            ("generic championship is not EFL", row("World Championship : India v Australia ᴸᶦᵛᵉ"),
             row("Live World Championship", subtitle: "India v Australia"), .unresolved),
            ("rugby is not EFL", row("United Rugby Championship : Ulster v Munster ᴸᶦᵛᵉ"),
             row("Live EFL Championship", subtitle: "Ulster v Munster"), .conflict),
            ("explicit rugby competition", row("United Rugby Championship : Ulster v Munster ᴸᶦᵛᵉ"),
             row("Live URC", subtitle: "Ulster v Munster"), .teams),
            ("multiple fixtures rejected", row("Premier League : Arsenal v Chelsea v Liverpool ᴸᶦᵛᵉ"),
             row("Live Premier League", subtitle: "Arsenal v Chelsea v Liverpool"), .unresolved),
            ("conflicting title subtitle teams", row("Premier League : Arsenal v Chelsea ᴸᶦᵛᵉ", subtitle: "Arsenal v Liverpool"),
             row("Live Premier League", subtitle: "Arsenal v Chelsea"), .unresolved)
        ]
    }

    private static func checkReports(_ aliases: SportsTeamAliases) throws {
        let provider = row("Good Morning Football : Episode 202 ᴸᶦᵛᵉ")
        let external = row("Good Morning Football", artwork: "https://example.invalid/programme.jpg")
        func report(_ rows: [ParsedProgramme], _ candidates: [ParsedProgramme], _ verified: Bool = true) -> EPGSportsProgrammeTrial.Report {
            EPGSportsProgrammeTrial.evaluate(provider: rows, external: candidates, aliases: verified ? ["channel": ["channel"]] : [:],
                                             names: ["channel": ["Sky Sports NFL"]], teamAliases: aliases)
        }
        let result = report([provider], [external])
        guard result.counts["studio"] == 1, result.candidateArtwork == 1, !result.publicationEnabled else { throw Failure(name: "candidate report") }
        guard report([provider, provider], [external]).counts["unresolved"] == 1 else { throw Failure(name: "provider duplicate") }
        guard report([provider], [external, external]).counts["unresolved"] == 1 else { throw Failure(name: "external duplicate") }
        guard report([provider], [external], false).counts["unresolved"] == 1 else { throw Failure(name: "verified station required") }
        guard report([provider], []).counts["unresolved"] == 1 else { throw Failure(name: "missing interval") }
        guard provider.artworkURL == nil else { throw Failure(name: "provider unchanged") }
    }

    private static func row(_ title: String, subtitle: String? = nil, description: String = "", offset: TimeInterval = 0,
                            duration: TimeInterval = 3600, artwork: String? = nil) -> ParsedProgramme
    {
        let start = Date(timeIntervalSince1970: 1_791_500_000 + offset)
        return ParsedProgramme(channelId: "channel", title: title, subtitle: subtitle, description: description, categories: [],
                               start: start, end: start.addingTimeInterval(duration), artworkURL: artwork)
    }
}
