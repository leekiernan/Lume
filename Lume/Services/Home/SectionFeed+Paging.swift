//
//  SectionFeed+Paging.swift
//  Lume
//
//  Paging a section's retained source list against the local catalog — the
//  continuation a full collection grid uses without refetching its remote
//  list. Split from SectionFeed.swift to keep it within the size limit.
//

import Foundation

extension SectionFeed {
    /// Resolves another local-catalog window from the retained source list.
    /// Nothing calls this from the 20-card rail; it is the common continuation
    /// path a full collection grid can use without refetching its remote list.
    func page(
        for section: HomeSectionRef,
        from cursor: Int,
        limit: Int = 100
    ) async -> SectionCollectionPage {
        guard let collection = collections[section], let context else {
            return SectionCollectionPage(items: [], nextOffset: cursor, hasMoreCandidates: false)
        }
        return await page(entries: collection.entries, from: cursor, limit: limit, context: context)
    }

    /// Resolves a page from a grid's captured source snapshot. A feed may
    /// revalidate while the grid is open; keeping that grid on one ordered
    /// source prevents its cursor from suddenly referring to a different list.
    func page(
        entries: [HomeListEntry],
        from cursor: Int,
        limit: Int = 100
    ) async -> SectionCollectionPage {
        guard let context else {
            return SectionCollectionPage(items: [], nextOffset: cursor, hasMoreCandidates: false)
        }
        return await page(entries: entries, from: cursor, limit: limit, context: context)
    }

    private func page(
        entries: [HomeListEntry],
        from cursor: Int,
        limit: Int,
        context: Context
    ) async -> SectionCollectionPage {
        await SectionCollectionResolver.page(
            entries: entries,
            from: cursor,
            limit: limit,
            context: context
        )
    }
}
