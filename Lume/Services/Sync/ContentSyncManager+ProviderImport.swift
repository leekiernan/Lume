import Foundation
import SwiftData

/// Only the common paging envelope, not a universal provider DTO. Each adapter
/// retains its authentication, decoding and model/relationship mapping.
nonisolated struct ProviderImportPage<Item> {
    let items: [Item]
    let total: Int
}

nonisolated enum ProviderImportError: Error, Equatable {
    case incompletePage(fetched: Int, expected: Int)
    case invalidTotal(Int)
}

nonisolated struct ProviderCategory {
    let id: String
    let name: String
    /// nil preserves an existing parent; providers without hierarchy use this.
    var parentID: Int?
}

extension ContentSyncManager {
    /// A completed walk is the authority to prune. An empty library is valid;
    /// an empty page before the advertised end is not. Already saved pages may
    /// remain after failure, but the caller must not sweep or mark coverage.
    func walkProviderPages<Item>(
        fetch: (Int) async throws -> ProviderImportPage<Item>,
        consume: ([Item]) throws -> Void,
        report: (Int, Int) async -> Void
    ) async throws -> Int {
        var fetched = 0
        while true {
            try Task.checkCancellation()
            let page = try await fetch(fetched)
            try Task.checkCancellation()
            guard page.total >= 0 else { throw ProviderImportError.invalidTotal(page.total) }
            guard !page.items.isEmpty || fetched >= page.total else {
                throw ProviderImportError.incompletePage(fetched: fetched, expected: page.total)
            }
            if !page.items.isEmpty { try consume(page.items) }
            fetched += page.items.count
            await report(fetched, page.total)
            try Task.checkCancellation()
            if fetched >= page.total { return fetched }
        }
    }

    /// Provider order/metadata are refreshed in place. User visibility, order,
    /// icons and on-demand freshness belong to the stored row, never the DTO.
    /// The lookup includes new inserts, so repeated IDs cannot replace them.
    func syncProviderCategories(_ rows: [ProviderCategory], type: CategoryType, playlistId: UUID) throws {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        var lookup = try fetchCategoryLookup(context: context, playlistId: playlistId, type: type)
        guard let playlist = try context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { return }

        var seen = Set<String>()
        for (index, row) in rows.enumerated() where !row.id.isEmpty {
            seen.insert(row.id)
            if let category = lookup[row.id] {
                if category.name != row.name { category.name = row.name }
                if let parentID = row.parentID, category.parentId != parentID { category.parentId = parentID }
                if category.sortOrder != index { category.sortOrder = index }
            } else {
                let category = Category(apiId: row.id, name: row.name, parentId: row.parentID ?? 0, type: type, playlist: playlist)
                category.sortOrder = index
                context.insert(category)
                lookup[row.id] = category
            }
        }
        if context.hasChanges { try context.save() }
        // Invalid/empty IDs do not constitute a successfully imported catalog.
        pruneCategories(playlistId: playlistId, type: type, seenApiIds: seen, importedCount: seen.count)
    }
}
