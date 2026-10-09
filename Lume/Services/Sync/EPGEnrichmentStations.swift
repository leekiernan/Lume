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

    /// External ID -> provider ID, only where every stream referencing that
    /// provider ID has the reviewed identity. Reject shared/ambiguous IDs even
    /// if one of their channel names looks right.
    static func aliases(for channels: [Channel]) -> [String: String] {
        let grouped = Dictionary(grouping: channels, by: \.epgID)
        var aliases: [String: String] = [:]
        for station in stations {
            guard let references = grouped[station.providerID], !references.isEmpty,
                  references.allSatisfy({ normalizedName($0.name) == normalizedName(station.name) }) else { continue }
            aliases[station.externalID] = station.providerID
        }
        return aliases
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
