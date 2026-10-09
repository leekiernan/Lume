import Foundation

/// Adversarial promotion gate, separate from passing baseline regressions.
/// Exit 1 means unsafe candidate acceptances remain; this must pass before rollout.
@main
struct EPGSportsValidationProbes {
    private static func row(_ title: String, _ description: String = "") -> ParsedProgramme {
        ParsedProgramme(channelId: "test", title: title, subtitle: nil, description: description, categories: [],
                        start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 3700))
    }

    static func main() {
        let cases: [(String, ParsedProgramme, ParsedProgramme)] = [
            ("adjacent explicit seasons", row("EFL: Arsenal v Chelsea", "2014/15 season"),
             row("EFL: Chelsea v Arsenal", "2015/16 season")),
            ("contradictory rounds inside source", row("International T20: India v West Indies ᴸᶦᵛᵉ", "2nd T20, third T20"),
             row("Live International T20: India v West Indies", "third T20")),
            ("contradictory episodes inside source", row("TNT Sports Reload: Episode 40", "E41"), row("TNT Sports Reload", "E41")),
            ("gender conflict in description", row("Premier League: Arsenal v Chelsea ᴸᶦᵛᵉ", "Women's football"),
             row("Live Premier League: Arsenal v Chelsea", "Men's football")),
            ("age conflict in description", row("Premier League: Arsenal v Chelsea ᴸᶦᵛᵉ", "Under-21 football"),
             row("Live Premier League: Arsenal v Chelsea", "Under-18 football")),
            ("numeric age qualifiers in team names", row("Premier League: England 21 v France 21 ᴸᶦᵛᵉ"),
             row("Live Premier League: England 18 v France 18"))
        ]
        var failures = 0
        for (name, provider, external) in cases {
            let decision = EPGSportsProgrammeIdentity.compare(provider, external, aliases: SportsTeamAliases(rawEntries: [:]))
            if decision.isCandidate || decision.kind == .strict { failures += 1 }
            print("\(name): \(decision.kind.rawValue); unsafe acceptance=\(decision.isCandidate || decision.kind == .strict)")
        }
        print("Promotion gate: \(failures) unsafe acceptances in \(cases.count) adversarial cases. App publication remains disabled.")
        if failures > 0 { exit(1) }
    }
}
