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

    /// Starts a new result set only when its query inputs changed. Returning to
    /// a grid from a detail screen keeps its loaded pages and scroll position.
    func prepare(for key: String) {
        guard requestKey != key else { return }
        requestKey = key
        items = []
        canLoadMore = true
        isLoading = false
    }

    /// Loads one page and preserves model identity/order. The descriptor owns
    /// the predicate and ordering; this type owns the common cursor and
    /// end-of-results contract.
    func loadNextPage(
        in context: ModelContext,
        pageSize: Int,
        descriptor: (_ offset: Int, _ limit: Int) -> FetchDescriptor<Item>
    ) {
        guard canLoadMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let page = try context.fetch(descriptor(items.count, pageSize))
            let existing = Set(items.map(\.persistentModelID))
            items.append(contentsOf: page.filter { !existing.contains($0.persistentModelID) })
            canLoadMore = page.count == pageSize
        } catch {
            // Preserve the already loaded window. A later appearance can retry
            // instead of turning a transient store failure into a false end.
        }
    }
}
