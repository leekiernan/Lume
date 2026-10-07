import Foundation

/// Small editorial selections, not claimed audience rankings. No remote
/// channel-registry dependency; IDs/aliases can grow after coverage is measured.
nonisolated enum LiveTVChannelCollections {
    struct Collection: Identifiable, Hashable {
        let id: String
        let title: String
        let channels: [LiveTVHubChannel]
    }

    private struct Station {
        let epgID: String
        let names: [String]
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

    static func resolve(_ channels: [LiveTVHubChannel]) -> [Collection] {
        let chosen = ukStations.compactMap { station in
            let names = Set(station.names.map(LiveTVTitleIndex.key))
            let matches = channels.filter {
                $0.epgID?.caseInsensitiveCompare(station.epgID) == .orderedSame || names.contains(channelKey($0.name))
            }
            // Favour the viewer's chosen version; otherwise use deterministic
            // provider order (the loader supplies num/name/id ordering).
            return matches.first(where: \.isFavorite) ?? matches.first
        }
        guard chosen.count >= 3 else { return [] }
        return [Collection(id: "uk-essentials", title: String(localized: "UK Essentials"), channels: chosen)]
    }

    static func channelKey(_ name: String) -> String {
        let clean = name.replacingOccurrences(of: #"(?i)^\s*UK\s*[|:·-]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s+(?:FHD|UHD|HD|SD|4K)\s*$"#, with: "", options: .regularExpression)
        // Do not strip +1 or region names: those are different schedules.
        return LiveTVTitleIndex.key(clean)
    }
}
