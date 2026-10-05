import Foundation
import SwiftData

/// Stored identity, not a provider DTO contract. Concrete descriptors keep
/// SwiftData predicates tied to the actual schema rather than protocol key paths.
nonisolated protocol CatalogImportRow: PersistentModel {
    var id: String { get }
    static func importDescriptor(ids: [String]) -> FetchDescriptor<Self>
}

nonisolated extension Movie: CatalogImportRow {
    static func importDescriptor(ids: [String]) -> FetchDescriptor<Movie> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.id) })
    }
}

nonisolated extension Series: CatalogImportRow {
    static func importDescriptor(ids: [String]) -> FetchDescriptor<Series> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.id) })
    }
}

nonisolated extension LiveStream: CatalogImportRow {
    static func importDescriptor(ids: [String]) -> FetchDescriptor<LiveStream> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.id) })
    }
}

nonisolated extension Episode: CatalogImportRow {
    static func importDescriptor(ids: [String]) -> FetchDescriptor<Episode> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.id) })
    }
}

/// A batch-local identity map. Never crosses executors or owns save/prune policy.
/// Failed reads throw: treating them as an empty catalog could replace user state.
nonisolated enum CatalogUpsert {
    static func lookup<Row: CatalogImportRow>(
        _ type: Row.Type, ids: [String], context: ModelContext
    ) throws -> [String: Row] {
        guard !ids.isEmpty else { return [:] }
        let rows = try context.fetch(type.importDescriptor(ids: ids))
        var lookup: [String: Row] = [:]
        lookup.reserveCapacity(ids.count)
        for row in rows {
            lookup[row.id] = row
        }
        return lookup
    }

    /// Insert only genuinely new identities, including when a page repeats one.
    static func row<Row: CatalogImportRow>(
        id: String, lookup: inout [String: Row], context: ModelContext, create: () -> Row
    ) -> Row {
        if let row = lookup[id] { return row }
        let row = create()
        context.insert(row)
        lookup[id] = row
        return row
    }

    /// Refiling must retain the episode instance and its progress; otherwise
    /// deleting its old shell can cascade-delete a still-playable episode.
    static func attach(_ episode: Episode, to series: Series) {
        if episode.series?.id != series.id { episode.series = series }
    }

    /// Provider mapping is explicit; the caller owns the transaction.
    static func batch<Items: Collection, Row: CatalogImportRow>(
        _ items: Items, context: ModelContext,
        identity: (Items.Element) -> String?,
        create: (Items.Element, String) -> Row,
        apply: (Items.Element, Row) -> Void
    ) throws -> [String] {
        let ids = items.compactMap(identity)
        var lookup = try lookup(Row.self, ids: ids, context: context)
        for item in items {
            guard let id = identity(item) else { continue }
            let row = row(id: id, lookup: &lookup, context: context) { create(item, id) }
            apply(item, row)
        }
        // Let the phase's existing accumulator deduplicate; a second temporary
        // set per batch would hash the same IDs twice on unchanged refreshes.
        return ids
    }
}

/// Preserve historical bytes: these IDs are also the keys of CloudKit user state.
/// Provider URL hashing/numeric conversion stays in each adapter.
nonisolated enum CatalogID {
    enum Kind: String { case movie, series, live }

    static func prefix(_ playlistId: UUID, infix: String) -> String {
        "\(playlistId.uuidString)-\(infix)-"
    }

    static func content(_ playlistId: UUID, kind: Kind, key: some CustomStringConvertible) -> String {
        prefix(playlistId, infix: kind.rawValue) + key.description
    }

    static func episode(prefix: String, key: String) -> String {
        prefix + "episode-" + key
    }

    static func episode(ownerID: String, key: String) -> String {
        ownerID + "-episode-" + key
    }
}
