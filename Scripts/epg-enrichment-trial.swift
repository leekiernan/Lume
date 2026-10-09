import Foundation

/// Compile with the production parser/matcher (command in epg-source-trial.md).
/// Reads saved guides only; never changes the app's catalog or source settings.
@main
struct EPGEnrichmentTrial {
    private struct Report: Encodable {
        let evaluatedAt: Date
        let verifiedStations: Int
        let providerIDs: Int
        let cachedProgrammes: Int
        let cacheBytes: Int
        let providerRows: Int
        let matchedRows: Int
        let enrichedRows: Int
        let restoredRows: Int
        let addedArtwork: Int
        let addedSubtitles: Int
        let addedCategories: Int
        let addedYears: Int
        let scheduleUnchanged: Bool
    }

    @MainActor static func main() throws {
        let arguments = CommandLine.arguments
        guard (6 ... 8).contains(arguments.count), let now = ISO8601DateFormatter().date(from: arguments[4]),
              let feed = EPGEnrichmentFeed.Identifier(rawValue: arguments.count >= 7 ? arguments[6] : "us-locals")
        else {
            throw TrialError.usage
        }
        let streams = try JSONDecoder().decode([EPGTrialStream].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
        let channels = streams.compactMap { stream -> EPGEnrichmentStations.Channel? in
            guard let id = stream.epgChannelID else { return nil }
            return .init(name: stream.name, epgID: id)
        }
        var aliases = EPGEnrichmentStations.aliases(for: channels, feed: feed)
        if arguments.count == 8 {
            let categories = Set(arguments[7].split(separator: ",").map(String.init))
            let selected = Set(streams.compactMap { stream -> String? in
                guard let category = stream.categoryID, categories.contains(category) else { return nil }
                return stream.epgChannelID
            })
            aliases = aliases.compactMapValues {
                let ids = $0.intersection(selected)
                return ids.isEmpty ? nil : ids
            }
            let mapped = Set(aliases.values.flatMap(\.self))
            let selection = streams.filter { $0.categoryID.map(categories.contains) == true }
            print("Category selection: \(selection.count) streams, \(selection.count(where: { $0.epgChannelID.map(mapped.contains) == true })) safely mapped")
            print("Unmapped: " + selection.filter { $0.epgChannelID.map(mapped.contains) != true }.map(\.name).joined(separator: ", "))
        }
        let providerIDs = Set(aliases.values.flatMap(\.self))
        let end = now.addingTimeInterval(48 * 3600)
        let provider = try programmes(at: URL(fileURLWithPath: arguments[2]), channelIDs: providerIDs, start: now, end: end)
        let external = try programmes(at: URL(fileURLWithPath: arguments[3]), channelIDs: Set(aliases.keys),
                                      start: now.addingTimeInterval(-2 * 3600), end: now.addingTimeInterval(4 * 86400))
        let snapshot = EPGEnrichmentCache(url: "offline-trial", checkedAt: now, channelIDs: Set(aliases.keys), programmes: external, lastModified: nil, entityTag: nil)
        guard snapshot.isUsable(url: snapshot.url, now: now) else { throw TrialError.invalidCache }
        let index = EPGProgrammeEnrichment.Index(programmes: external, aliases: aliases)
        let report = try evaluate(provider, index: index, now: now, snapshot: snapshot, providerIDs: providerIDs.count)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: URL(fileURLWithPath: arguments[5]), options: .atomic)
        print(String(data: data, encoding: .utf8) ?? "")
    }

    @MainActor private static func evaluate(_ provider: [ParsedProgramme], index: EPGProgrammeEnrichment.Index, now: Date, snapshot: EPGEnrichmentCache, providerIDs: Int) throws -> Report {
        var matched = 0
        var enriched = 0
        var restored = 0
        var artwork = 0
        var subtitles = 0
        var categories = 0
        var years = 0
        for programme in provider {
            let row = EPGListing(
                id: "trial", channelId: programme.channelId, title: programme.title, listingDescription: programme.description,
                start: programme.start, end: programme.end, subtitle: programme.subtitle,
                category: programme.categories.isEmpty ? nil : programme.categories.joined(separator: ", "),
                artworkURL: programme.artworkURL, releaseYear: programme.releaseYear
            )
            let original = EPGProgrammeEnrichment.Metadata(row)
            if index.metadata(channelID: row.channelId, start: row.start, end: row.end, title: row.title) != nil { matched += 1 }
            if try EPGProgrammeEnrichment.apply(index, to: row) { enriched += 1 }
            if original.artworkURL != row.artworkURL { artwork += 1 }
            if original.subtitle != row.subtitle { subtitles += 1 }
            if original.category != row.category { categories += 1 }
            if original.releaseYear != row.releaseYear { years += 1 }
            guard row.title == programme.title, row.channelId == programme.channelId, row.start == programme.start, row.end == programme.end else {
                throw TrialError.changedSchedule
            }
            if try EPGProgrammeEnrichment.apply(.init(), to: row) { restored += 1 }
            guard EPGProgrammeEnrichment.Metadata(row) == original, row.enrichmentBaseline == nil else { throw TrialError.changedProviderMetadata }
        }
        return try Report(
            evaluatedAt: now, verifiedStations: snapshot.channelIDs.count, providerIDs: providerIDs,
            cachedProgrammes: snapshot.programmes.count, cacheBytes: JSONEncoder().encode(snapshot).count,
            providerRows: provider.count, matchedRows: matched,
            enrichedRows: enriched, restoredRows: restored, addedArtwork: artwork, addedSubtitles: subtitles,
            addedCategories: categories, addedYears: years, scheduleUnchanged: true
        )
    }

    private static func programmes(at url: URL, channelIDs: Set<String>, start: Date, end: Date) throws -> [ParsedProgramme] {
        let file = try GzipFile.isGzip(url) ? GzipFile.decompress(url) : url
        defer { if file != url { try? FileManager.default.removeItem(at: file) } }
        var rows: [ParsedProgramme] = []
        let outcome = XMLTVParser.parse(fileURL: file, channelIDs: channelIDs) { batch in
            rows += batch.filter { $0.end > start && $0.start < end && $0.end > $0.start }
        }
        guard outcome.succeeded else { throw TrialError.invalidXMLTV }
        return rows
    }

    private enum TrialError: Error {
        case usage // streams.json provider.xml supplement.xml.gz ISO8601-instant report.json [uk|us-locals] [categoryIDs,comma-separated]
        case invalidXMLTV
        case invalidCache
        case changedSchedule
        case changedProviderMetadata
    }
}

private struct EPGTrialStream: Decodable {
    let name: String
    let epgChannelID: String?
    let categoryID: String?

    enum CodingKeys: String, CodingKey {
        case name
        case epgChannelID = "epg_channel_id"
        case categoryID = "category_id"
    }
}
