import Foundation

/// Enrichment never claims channels or changes their schedule. Only an exact
/// channel/start/end/normalized-title match may fill missing provider fields.
nonisolated enum EPGProgrammeEnrichment {
    struct Key: Hashable {
        let channelID: String
        let start: Date
        let end: Date
        let title: String

        init(channelID: String, start: Date, end: Date, title: String) {
            self.channelID = channelID
            self.start = start
            self.end = end
            self.title = normalizedTitle(title)
        }
    }

    struct Metadata: Codable, Equatable {
        var description: String
        var subtitle: String?
        var category: String?
        var artworkURL: String?
        var releaseYear: String?

        init(_ programme: ParsedProgramme) {
            description = programme.description
            subtitle = programme.subtitle
            category = programme.categories.isEmpty ? nil : programme.categories.joined(separator: ", ")
            artworkURL = programme.artworkURL
            releaseYear = programme.releaseYear
        }

        init(_ listing: EPGListing) {
            description = listing.listingDescription
            subtitle = listing.subtitle
            category = listing.category
            artworkURL = listing.artworkURL
            releaseYear = listing.releaseYear
        }

        func fillingMissing(from other: Metadata) -> Metadata {
            var result = self
            if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.description = other.description }
            if Self.isMissing(subtitle) { result.subtitle = other.subtitle }
            if Self.isMissing(category) { result.category = other.category }
            if Self.isMissing(artworkURL) { result.artworkURL = other.artworkURL }
            if Self.isMissing(releaseYear) { result.releaseYear = other.releaseYear }
            return result
        }

        private static func isMissing(_ value: String?) -> Bool {
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        }
    }

    struct Index {
        private var entries: [Key: Metadata] = [:]
        private var ambiguous: Set<Key> = []

        init(merging indexes: [Self]) {
            for index in indexes {
                ambiguous.formUnion(index.ambiguous)
                for (key, metadata) in index.entries {
                    if let previous = entries[key], previous != metadata { ambiguous.insert(key) }
                    entries[key] = metadata
                }
            }
            for key in ambiguous {
                entries.removeValue(forKey: key)
            }
        }

        init(programmes: [ParsedProgramme] = [], aliases: [String: String] = [:]) {
            for programme in programmes {
                guard let channel = aliases[programme.channelId], programme.end > programme.start else { continue }
                let key = Key(channelID: channel, start: programme.start, end: programme.end, title: programme.title)
                guard !key.title.isEmpty, !ambiguous.contains(key) else { continue }
                let metadata = Metadata(programme)
                if let existing = entries[key], existing != metadata {
                    // Conflicting duplicates must not win by document order.
                    entries.removeValue(forKey: key)
                    ambiguous.insert(key)
                } else {
                    entries[key] = metadata
                }
            }
        }

        func metadata(channelID: String, start: Date, end: Date, title: String) -> Metadata? {
            entries[Key(channelID: channelID, start: start, end: end, title: title)]
        }
    }

    static func normalizedTitle(_ title: String) -> String {
        var value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("ᴺᵉʷ") { value.removeLast(3) }
        return value.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Returns whether reader-visible metadata changed. Disabling enrichment,
    /// an expired cache, a missing alias or a mismatching replacement restores
    /// the original provider fields. Decode failure aborts publication.
    @discardableResult
    static func apply(_ index: Index, to listing: EPGListing) throws -> Bool {
        let current = Metadata(listing)
        let baseline = try listing.enrichmentBaseline.map { try JSONDecoder().decode(Metadata.self, from: $0) } ?? current
        let supplement = index.metadata(channelID: listing.channelId, start: listing.start, end: listing.end, title: listing.title)
        let effective = supplement.map { baseline.fillingMissing(from: $0) } ?? baseline
        let encoded = effective == baseline ? nil : try JSONEncoder().encode(baseline)
        if listing.enrichmentBaseline != encoded { listing.enrichmentBaseline = encoded }
        guard effective != current else { return false }
        listing.listingDescription = effective.description
        listing.subtitle = effective.subtitle
        listing.category = effective.category
        listing.artworkURL = effective.artworkURL
        listing.releaseYear = effective.releaseYear
        return true
    }
}
