import Foundation

/// Small editorial selections, not claimed audience rankings. No remote
/// channel-registry dependency; IDs/aliases can grow after coverage is measured.
nonisolated enum LiveTVChannelCollections {
    /// Bundled editorial catalog, reviewed against iptv-org on 7 October 2026.
    /// Increment when changing membership/order; stable rail IDs stay unchanged.
    static let catalogVersion = 1
    struct Collection: Identifiable, Hashable {
        let id: String
        let title: String
        let channels: [LiveTVHubChannel]
    }

    private struct Station {
        let epgID: String
        let names: [String]
    }

    private struct Selection {
        let row: LiveTVHubRow
        let stations: [Station]
        var country: String {
            String(row.id.prefix(2))
        }

        var title: String {
            row.title
        }
    }

    private static let ukStations: [Station] = [
        .init(epgID: "BBCOne.uk", names: ["BBC One", "BBC 1"]),
        .init(epgID: "BBCTwo.uk", names: ["BBC Two", "BBC 2"]),
        .init(epgID: "ITV1.uk", names: ["ITV1", "ITV 1"]),
        .init(epgID: "Channel4.uk", names: ["Channel 4"]),
        .init(epgID: "Channel5.uk", names: ["Channel 5"]),
        .init(epgID: "BBCFour.uk", names: ["BBC Four", "BBC 4"]),
        .init(epgID: "BBCNews.uk", names: ["BBC News"]),
        .init(epgID: "SkyNews.uk", names: ["Sky News"])
    ]

    private static var selections: [Selection] {
        [
            .init(row: .unitedKingdom, stations: ukStations),
            .init(row: .unitedStates, stations: [
                .init(epgID: "ABC.us", names: ["ABC"]),
                .init(epgID: "CBS.us", names: ["CBS"]),
                .init(epgID: "NBC.us", names: ["NBC"]),
                .init(epgID: "Fox.us", names: ["FOX"]),
                .init(epgID: "PBS.us", names: ["PBS"]),
                .init(epgID: "CNN.us", names: ["CNN"]),
                .init(epgID: "MSNBC.us", names: ["MSNBC"]),
                .init(epgID: "ESPN.us", names: ["ESPN"])
            ]),
            .init(row: .canada, stations: [
                .init(epgID: "CBCTelevision.ca", names: ["CBC", "CBC TV", "CBC Television"]),
                .init(epgID: "CTV.ca", names: ["CTV"]),
                .init(epgID: "GlobalTelevisionNetwork.ca", names: ["Global", "Global TV", "Global Television Network"]),
                .init(epgID: "Citytv.ca", names: ["Citytv", "City TV"]),
                .init(epgID: "CBCNewsNetwork.ca", names: ["CBC News Network"]),
                .init(epgID: "CTVNewsChannel.ca", names: ["CTV News Channel"]),
                .init(epgID: "TVO.ca", names: ["TVO"]),
                .init(epgID: "Sportsnet.ca", names: ["Sportsnet"]),
                .init(epgID: "TSN1.ca", names: ["TSN1", "TSN 1"])
            ]),
            .init(row: .australia, stations: [
                .init(epgID: "ABCTV.au", names: ["ABC TV", "ABC"]),
                .init(epgID: "Channel7.au", names: ["Channel 7", "Seven", "Seven Network", "7"]),
                .init(epgID: "Channel9.au", names: ["Channel 9", "Nine", "Nine Network", "9"]),
                .init(epgID: "10.au", names: ["10", "Channel 10", "Network 10", "Ten"]),
                .init(epgID: "SBS.au", names: ["SBS"]),
                .init(epgID: "ABCNews.au", names: ["ABC News"]),
                .init(epgID: "SBSViceland.au", names: ["SBS Viceland"]),
                .init(epgID: "7mate.au", names: ["7mate"])
            ]),
            .init(row: .newZealand, stations: [
                .init(epgID: "TVNZ1.nz", names: ["TVNZ 1", "TVNZ One"]),
                .init(epgID: "TVNZ2.nz", names: ["TVNZ 2", "TVNZ Two"]),
                .init(epgID: "Three.nz", names: ["Three", "TV3"]),
                .init(epgID: "SkyOpen.nz", names: ["Sky Open", "Prime"]),
                .init(epgID: "TVNZDUKE.nz", names: ["TVNZ Duke"]),
                .init(epgID: "Bravo.nz", names: ["Bravo"]),
                .init(epgID: "TeReo.nz", names: ["Te Reo"])
            ]),
            .init(row: .southAfrica, stations: [
                .init(epgID: "SABC1.za", names: ["SABC 1"]),
                .init(epgID: "SABC2.za", names: ["SABC 2"]),
                .init(epgID: "SABC3.za", names: ["SABC 3"]),
                .init(epgID: "etv.za", names: ["e.tv", "eTV"]),
                .init(epgID: "SABCNews.za", names: ["SABC News"]),
                .init(epgID: "eNewsChannelAfrica.za", names: ["eNCA", "eNews Channel Africa"]),
                .init(epgID: "NewzroomAfrika.za", names: ["Newzroom Afrika"]),
                .init(epgID: "MzansiMagic.za", names: ["Mzansi Magic"])
            ])
        ]
    }

    private static let countryPrefixes = ["uk": "uk", "gb": "uk", "us": "us", "usa": "us",
                                          "ca": "ca", "can": "ca", "au": "au", "aus": "au", "nz": "nz", "za": "za", "sa": "za"]
    private static let ambiguousNames: Set<String> = ["abc", "abcnews", "sbs", "bravo", "10", "7", "9", "three", "prime", "global"]

    static func resolve(_ channels: [LiveTVHubChannel]) -> [Collection] {
        // Normalise once per channel, not once per station/country/channel pair.
        let byID = Dictionary(grouping: channels, by: { canonicalID($0.epgID ?? "") })
        let byName = Dictionary(grouping: channels, by: { channelKey($0.name) })
        return selections.compactMap { selection in
            var seen: Set<String> = []
            let chosen = selection.stations.compactMap { station -> LiveTVHubChannel? in
                let exact = byID[station.epgID.lowercased()] ?? []
                let aliases = station.names.flatMap { byName[LiveTVTitleIndex.key($0)] ?? [] }
                    .filter { matchesCountry($0, country: selection.country) }
                // A canonical schedule ID outranks a name-only favourite. Then
                // favour the chosen version within that match tier.
                let matches = exact.isEmpty ? aliases : exact
                guard let channel = matches.first(where: \.isFavorite) ?? matches.first,
                      seen.insert(channel.id).inserted else { return nil }
                return channel
            }
            guard chosen.count >= 3 else { return nil }
            return Collection(id: "\(selection.country)-essentials", title: selection.title, channels: chosen)
        }
    }

    private static func canonicalID(_ raw: String) -> String {
        // Feed suffixes identify versions of the same station; region/+1 IDs
        // remain separate and are never collapsed by a fuzzy name match.
        raw.split(separator: "@", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
    }

    private static func countryHint(_ channel: LiveTVHubChannel) -> String? {
        let prefix = channel.name.split(whereSeparator: { "|:·-".contains($0) }).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if let prefix, let country = countryPrefixes[prefix] { return country }
        let suffix = canonicalID(channel.epgID ?? "").split(separator: ".").last.map(String.init)
        guard let suffix, suffix.count == 2 else { return nil }
        return countryPrefixes[suffix] ?? suffix
    }

    private static func matchesCountry(_ channel: LiveTVHubChannel, country: String) -> Bool {
        if let hint = countryHint(channel) { return hint == country }
        // ABC, SBS, Bravo, etc. exist in several countries. Don't silently put
        // an unlabelled foreign station into a country's selection.
        return !ambiguousNames.contains(channelKey(channel.name))
    }

    static func channelKey(_ name: String) -> String {
        let clean = name.replacingOccurrences(of: #"(?i)^\s*(?:UK|GB|US|USA|CA|CAN|AU|AUS|NZ|ZA|SA)\s*[|:·-]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s+(?:FHD|UHD|HD|SD|4K)\s*$"#, with: "", options: .regularExpression)
        // Do not strip +1 or region names: those are different schedules.
        return LiveTVTitleIndex.key(clean)
    }
}
