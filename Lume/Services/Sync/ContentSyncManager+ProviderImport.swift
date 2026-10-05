import Foundation
import OSLog
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

    /// Walks one library. A walk the server cut short — fewer items than it
    /// advertised, or a nonsense total — keeps that library's rows and returns
    /// the error instead of throwing, so the other libraries still import.
    /// The caller skips pruning that kind and reports the error once every
    /// library has had its turn, which keeps `lastSyncDate` and coverage from
    /// advancing. Any other failure (network, auth, cancellation) throws.
    func walkLibrary(_ name: String, _ walk: () async throws -> Void) async throws -> ProviderImportError? {
        do {
            try await walk()
            return nil
        } catch let error as ProviderImportError {
            Logger.database.error("Library \(name, privacy: .public) walk incomplete (\(String(describing: error), privacy: .public)); its rows are kept and its kind isn't pruned")
            return error
        }
    }

    /// Continue after structural truncation, retaining the first error as the
    /// phase's prune veto. Transport/auth/storage/cancellation failures stop.
    func walkLibraries<Library>(
        _ libraries: [Library], name: KeyPath<Library, String>, walk: (Library) async throws -> Void
    ) async throws -> ProviderImportError? {
        var incomplete: ProviderImportError?
        for library in libraries {
            try Task.checkCancellation()
            let failure = try await walkLibrary(library[keyPath: name]) { try await walk(library) }
            incomplete = incomplete ?? failure
        }
        try Task.checkCancellation()
        return incomplete
    }

    /// Provider order/metadata are refreshed in place. User visibility, order,
    /// icons and on-demand freshness belong to the stored row, never the DTO.
    /// The lookup includes new inserts, so repeated IDs cannot replace them.
    ///
    /// `keepsEmptyIDs`: Xtream has always stored a category whose provider id is
    /// empty (as `<uuid>-<type>-`), and its titles may point at it; skipping it
    /// would prune that row and drop them from browse. Every other provider
    /// treats an empty id as unusable.
    func syncProviderCategories(
        _ rows: [ProviderCategory], type: CategoryType, playlistId: UUID, keepsEmptyIDs: Bool = false
    ) throws {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        var lookup = try fetchCategoryLookup(context: context, playlistId: playlistId, type: type)
        guard let playlist = try context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { return }

        var seen = Set<String>()
        for (index, row) in rows.enumerated() where keepsEmptyIDs || !row.id.isEmpty {
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
