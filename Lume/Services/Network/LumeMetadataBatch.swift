import Foundation

nonisolated enum LumeMetadataKind: String, Decodable {
    case movie, series
}

nonisolated enum LumeMetadataError: Error {
    case incomplete, unavailable
}

/// Local proof, never decoded from a catalogue row. No URLs or credentials are
/// persisted. Separate scalar/full lanes preserve the cast-context boundary.
nonisolated struct LumeMetadataReceipt: Codable, Equatable {
    static let freshnessWindow: TimeInterval = 14 * 24 * 3600
    let sourceIdentity: String
    let tmdbID: Int
    let language: String
    let tmdbAt: Date
    let artworkAt: Date

    func matches(source: LumeProxySource?, tmdbID: Int?, language: String) -> Bool {
        source?.identity == sourceIdentity && self.tmdbID == tmdbID && self.language == language
    }

    static func isFresh(_ date: Date?, now: Date = Date()) -> Bool {
        guard let date else { return false }
        return date <= now && now.timeIntervalSince(date) < freshnessWindow
    }
}

/// The network envelope certifies identity and language; each item independently
/// certifies complete TMDB + artwork groups. A bad/missing item is a cache miss,
/// not a reason to discard other valid titles in the same batch.
nonisolated struct LumeMetadataBatch: Decodable {
    let version: Int
    let type: LumeMetadataKind
    let language: String
    private let items: [LumeMetadataBatchItem]
    private let duplicateIDs: Set<Int>

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case type, language, items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        type = try container.decode(LumeMetadataKind.self, forKey: .type)
        language = try container.decode(String.self, forKey: .language)
        var entries = try container.nestedUnkeyedContainer(forKey: .items)
        guard (entries.count ?? 51) <= 50 else { throw LumeMetadataError.incomplete }
        var decoded: [LumeMetadataBatchItem] = []
        var seen: Set<Int> = []
        var duplicates: Set<Int> = []
        while !entries.isAtEnd {
            let itemDecoder = try entries.superDecoder()
            if let container = try? itemDecoder.container(keyedBy: LumeMetadataBatchItem.CodingKeys.self),
               let id = try? container.decode(Int.self, forKey: .id), !seen.insert(id).inserted { duplicates.insert(id) }
            if let item = try? LumeMetadataBatchItem(from: itemDecoder, type: type, language: language) { decoded.append(item) }
        }
        items = decoded
        duplicateIDs = duplicates
    }

    func details(source: LumeProxySource, requestedIDs: Set<Int>, capabilities: LumeProxyCapabilities, now: Date) -> [Int: TMDBTitleDetails] {
        var result: [Int: TMDBTitleDetails] = [:]
        for item in items where requestedIDs.contains(item.id) && !duplicateIDs.contains(item.id) {
            guard let tmdbAt = item.availability.availableAt(for: .tmdb, capabilities: capabilities, now: now),
                  let artworkAt = item.availability.availableAt(for: .artwork, capabilities: capabilities, now: now),
                  LumeMetadataReceipt.isFresh(tmdbAt, now: now), LumeMetadataReceipt.isFresh(artworkAt, now: now)
            else { continue }
            var applied = item.details
            applied.proxyReceipt = LumeMetadataReceipt(sourceIdentity: source.identity, tmdbID: item.id, language: language,
                                                       tmdbAt: tmdbAt, artworkAt: artworkAt)
            result[item.id] = applied
        }
        return result
    }
}

private nonisolated struct LumeMetadataBatchItem {
    let id: Int
    let availability: LumeMetadataAvailability
    let details: TMDBTitleDetails
    enum CodingKeys: String, CodingKey {
        case id = "tmdb_id"
        case availability = "lume_meta"
        case payload = "tmdb"
    }

    init(from decoder: Decoder, type: LumeMetadataKind, language: String) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        availability = try container.decode(LumeMetadataAvailability.self, forKey: .availability)
        let payloadDecoder = try container.superDecoder(forKey: .payload)
        let identity = try payloadDecoder.container(keyedBy: PayloadKey.self).decode(Int.self, forKey: .id)
        guard id > 0, identity == id else { throw LumeMetadataError.incomplete }
        // Normalization is shared with direct TMDB; do not introduce a
        // second mapping with subtly different cast/video/logo semantics.
        details = try TMDBClient.proxyDetails(from: payloadDecoder, type: type, language: language)
    }

    private enum PayloadKey: String, CodingKey { case id }
}
