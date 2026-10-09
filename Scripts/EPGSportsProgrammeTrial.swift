import Foundation

/// Explains every bounded sports pairing without changing guide metadata.
/// Identity aliases come from the shipping full-catalog station verification.
nonisolated enum EPGSportsProgrammeTrial {
    struct Entry: Encodable {
        let channelID: String
        let channels: [String]
        let start: Date
        let end: Date
        let providerTitle: String
        let providerSubtitle: String?
        let providerDescription: String
        let externalTitle: String?
        let externalSubtitle: String?
        let externalDescription: String?
        let decision: EPGSportsProgrammeIdentity.Decision
        let wouldAddArtwork: Bool
    }

    struct Report: Encodable {
        let rulesVersion = 1
        let publicationEnabled = false
        let counts: [String: Int]
        let reasons: [String: Int]
        let candidateArtwork: Int
        let entries: [Entry]
    }

    private struct Interval: Hashable {
        let channelID: String
        let start: Date
        let end: Date
    }

    static func evaluate(provider: [ParsedProgramme], external: [ParsedProgramme], aliases: EPGEnrichmentStations.Aliases,
                         names: [String: [String]], teamAliases: SportsTeamAliases) -> Report
    {
        let selected = provider.filter { row in
            names[row.channelId]?.contains { name in
                let folded = name.lowercased()
                return folded.hasPrefix("sky sports") || folded.hasPrefix("tnt sports") || folded.hasPrefix("premier sports")
            } == true
        }
        let byProvider = Dictionary(grouping: selected, by: key)
        var byExternal: [Interval: [ParsedProgramme]] = [:]
        for row in external {
            for id in (aliases[row.channelId] ?? []).sorted() {
                byExternal[Interval(channelID: id, start: row.start, end: row.end), default: []].append(row)
            }
        }
        var entries: [Entry] = []
        for interval in byProvider.keys.sorted(by: ordered) {
            guard let rows = byProvider[interval], let row = rows.first else { continue }
            let candidates = byExternal[interval] ?? []
            let external = candidates.count == 1 ? candidates.first : nil
            let decision: EPGSportsProgrammeIdentity.Decision = if rows.count != 1 || candidates.count > 1 {
                .init(kind: .unresolved, reasons: ["ambiguous interval; duplicate programmes rejected"])
            } else if let external {
                EPGSportsProgrammeIdentity.compare(row, external, aliases: teamAliases)
            } else {
                .init(kind: .unresolved, reasons: ["no external programme with exact interval"])
            }
            entries.append(Entry(channelID: interval.channelID, channels: names[interval.channelID] ?? [], start: row.start, end: row.end,
                                 providerTitle: row.title, providerSubtitle: row.subtitle, providerDescription: String(row.description.prefix(800)),
                                 externalTitle: external?.title, externalSubtitle: external?.subtitle, externalDescription: external.map { String($0.description.prefix(800)) },
                                 decision: decision, wouldAddArtwork: decision.isCandidate && row.artworkURL?.isEmpty != false && external?.artworkURL?.isEmpty == false))
        }
        var counts: [String: Int] = [:]
        var reasons: [String: Int] = [:]
        for entry in entries {
            counts[entry.decision.kind.rawValue, default: 0] += 1
            for reason in entry.decision.reasons {
                reasons[reason, default: 0] += 1
            }
        }
        return Report(counts: counts, reasons: reasons, candidateArtwork: entries.count(where: \.wouldAddArtwork), entries: entries)
    }

    private static func key(_ row: ParsedProgramme) -> Interval {
        Interval(channelID: row.channelId, start: row.start, end: row.end)
    }

    private static func ordered(_ left: Interval, _ right: Interval) -> Bool {
        (left.channelID, left.start, left.end) < (right.channelID, right.start, right.end)
    }
}
