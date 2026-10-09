import Foundation

/// The reviewed aliases from the outside-app trial. Deliberately not a fuzzy
/// callsign/network matcher: an affiliate, timezone or subchannel must not be
/// inferred from a generic PBS label. Expand only after testing actual guides.
nonisolated enum EPGEnrichmentStations {
    struct Channel {
        let name: String
        let epgID: String
    }

    private static let stations: [(name: String, providerID: String, externalID: String)] = [
        ("US PBS (GPB) Atlanta", "pbswgtv.us", "WGTV-DT.us_locals1"),
        ("US PBS (KAET) Phoenix", "PBSKAET.us", "KAET-DT.us_locals1"),
        ("US PBS (KAKM) Anchorage", "PBSKAKM.us", "KAKM-DT.us_locals1"),
        ("US PBS (KBDI) Denver-Broomfield", "PBSKBDI.us", "KBDI-DT.us_locals1"),
        ("US PBS (KCPT) Kansas City", "PBSKCPT.us", "KCPT-DT.us_locals1"),
        ("US PBS (KCTS) Seattle", "PBSKCTS.us", "KCTS-DT.us_locals1"),
        ("US PBS (KDIN) Des Moines", "PBSKDIN.us", "KDIN-DT.us_locals1"),
        ("US PBS (KLRN) San Antonio", "PBSKLRN.us", "KLRN-DT.us_locals1"),
        ("US PBS (KNME) Albuquerque", "PBSKNME.us", "KNME-DT.us_locals1"),
        ("US PBS (KOCE) Los Angeles", "PBSKOCE.us", "KOCE-DT.us_locals1"),
        ("US PBS (KPBS) San Diego", "PBSKPBS.us", "KPBS-DT.us_locals1"),
        ("US PBS (KQED) San Francisco", "PBSKQED.us", "KQED-DT.us_locals1"),
        ("US PBS (KRMA) Denver", "PBSKRMA.us", "KRMA-DT.us_locals1"),
        ("US PBS 8 (KUHT) Houston", "PBSKUHT.us", "KUHT-DT.us_locals1"),
        ("US PBS (WETA) Arlington", "PBSWETA.us", "WETA-DT.us_locals1"),
        ("US PBS (WGBH) Boston", "PBSWGBH.us", "WGBH-DT.us_locals1"),
        ("US PBS (WNET) New York", "PBSWNET.us", "WNET-DT.us_locals1"),
        ("US PBS (WTTW) Chicago", "PBSWTTW.us", "WTTW-DT.us_locals1"),
        ("US PBS (WNED) Buffalo", "PBS.us", "WNED-DT.us_locals1"),
        ("US PBS (WHYY) Philadelphia", "PBSWHYY.us", "WHYY-DT.us_locals1")
    ]

    private static let ukStations: [(names: [String], providerID: String, externalID: String)] = [
        (["BBC ONE LONDON FHD"], "bbconelondon.uk", "BBC.One.Lon.HD.uk"),
        (["BBC ONE SCOTLAND FHD"], "BBCOneScotland.uk", "BBC.One.ScotHD.uk"),
        (["BBC TWO FHD", "BBC TWO HD", "BBC TWO SD"], "BBCTwo.uk", "BBC.Two.HD.uk"),
        (["CHANNEL 4 FHD", "CHANNEL 4 HD", "CHANNEL 4 SD"], "Channel4.uk", "Channel.4.HD.uk"),
        (["CHANNEL 5 FHD", "CHANNEL 5 HD", "CHANNEL 5 SD"], "Channel5.uk", "Channel.5.HD.uk"),
        (["BBC NEWS FHD", "BBC NEWS HD", "BBC NEWS SD"], "BBCNewsChannel.uk", "BBC.NEWS.HD.uk"),
        (["SKY NEWS FHD", "SKY NEWS HD", "SKY NEWS SD"], "SkyNews.uk", "Sky.News.HD.uk"),
        (["Sky Sports Football HD"], "skysportsfootball.uk", "Sky.Sports.Football.HD.uk"),
        (["Sky Sports NFL FHD", "Sky Sports NFL FHD 50FPS", "Sky Sports NFL SD"], "SkySportsAction.uk", "Sky.Sports.NFL.uk"),
        (["TNT SPORTS 1 FHD 50FPS", "TNT Sports 1 FHD"], "TNTSports1.uk", "TNT.Sports.1.HD.uk"),
        (["TNT SPORTS 2 FHD 50FPS", "TNT Sports 2 FHD", "TNT Sports 2 HD"], "TNTSports2.uk", "TNT.Sports.2.HD.uk"),
        (["TNT SPORTS 3 FHD 50FPS", "TNT Sports 3 FHD", "TNT Sports 3 HD"], "TNTSports3.uk", "TNT.Sports.3.HD.uk"),
        (["TNT Sports 4 FHD", "TNT Sports 4 FHD 50FPS", "TNT Sports 4 HD"], "TNTSports4.uk", "TNT.Sports.4.HD.uk")
    ]

    private static func reviewed(_ feed: EPGEnrichmentFeed.Identifier) -> [(names: [String], providerID: String, externalID: String)] {
        feed == .britain ? ukStations : stations.map { ([$0.name], $0.providerID, $0.externalID) }
    }

    static func providerIDs(for feed: EPGEnrichmentFeed.Identifier) -> Set<String> {
        Set(reviewed(feed).map(\.providerID))
    }

    /// External ID -> provider ID, only where every stream referencing that
    /// provider ID has the reviewed identity. Reject shared/ambiguous IDs even
    /// if one of their channel names looks right.
    static func aliases(for channels: [Channel], feed: EPGEnrichmentFeed.Identifier = .usPBS) -> [String: String] {
        let grouped = Dictionary(grouping: channels, by: \.epgID)
        var aliases: [String: String] = [:]
        for station in reviewed(feed) {
            let names = Set(station.names.map(normalizedName))
            guard let references = grouped[station.providerID], !references.isEmpty,
                  references.allSatisfy({ names.contains(normalizedName($0.name)) }) else { continue }
            aliases[station.externalID] = station.providerID
        }
        return aliases
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
