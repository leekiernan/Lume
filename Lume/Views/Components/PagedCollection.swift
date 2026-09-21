//
//  PagedCollection.swift
//  Lume
//
//  Shared incremental SwiftData loading for full collection grids. Category,
//  genre and library collections should hydrate only the window the viewer has
//  reached, rather than materialising an entire catalog-backed result.
//

import SwiftData
import SwiftUI

@MainActor
@Observable
final class PagedCollection<Item: PersistentModel> {
    private(set) var items: [Item] = []
    private(set) var canLoadMore = true
    private(set) var isLoading = false

    private var requestKey: String?
    /// Source cursor is distinct from `items.count` when a fork-specific
    /// presentation collapses duplicate catalog rows.
    private var sourceOffset = 0

    /// Starts a new result set only when its query inputs changed. Returning to
    /// a grid from a detail screen keeps its loaded pages and scroll position.
    func prepare(for key: String) {
        guard requestKey != key else { return }
        requestKey = key
        items = []
        sourceOffset = 0
        canLoadMore = true
        isLoading = false
    }

    /// Loads one page and preserves model identity/order. The descriptor owns
    /// the predicate and ordering; this type owns the common cursor and
    /// end-of-results contract.
    func loadNextPage(
        in context: ModelContext,
        pageSize: Int,
        deduplicateBy: ((Item) -> AnyHashable?)? = nil,
        descriptor: (_ offset: Int, _ limit: Int) -> FetchDescriptor<Item>
    ) {
        guard canLoadMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            var existingIDs = Set(items.map(\.persistentModelID))
            var existingKeys = Set(items.compactMap { deduplicateBy?($0) })
            var accepted: [Item] = []

            // A whole source page can consist of alternate streams for titles
            // already shown. Keep walking until the UI gains a new trailing
            // card (which can trigger its next onAppear) or the source ends.
            repeat {
                let page = try context.fetch(descriptor(sourceOffset, pageSize))
                sourceOffset += page.count
                canLoadMore = page.count == pageSize
                accepted.append(contentsOf: page.filter { item in
                    guard existingIDs.insert(item.persistentModelID).inserted else { return false }
                    guard let key = deduplicateBy?(item) else { return true }
                    return existingKeys.insert(key).inserted
                })
            } while accepted.isEmpty && canLoadMore

            items.append(contentsOf: accepted)
        } catch {
            // Preserve the already loaded window. A later appearance can retry
            // instead of turning a transient store failure into a false end.
        }
    }
}
