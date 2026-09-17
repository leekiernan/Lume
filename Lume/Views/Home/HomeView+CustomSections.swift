//
//  HomeView+CustomSections.swift
//  Lume
//
//  Loading for the user's custom Home rows (Settings › Layout › Home › Add
//  Section). Each row is a public list URL resolved by `HomeListCatalog`, then
//  matched against the local catalog by TMDB id — the same batched lookup the
//  trending and Trakt rows use, so a custom row only ever shows titles the
//  active playlist actually carries.
//

import SwiftUI

extension HomeView {
    /// How many matched titles a custom row shows. Matches the trending rails'
    /// cap — the source lists run to 50 entries.
    static var customSectionItemLimit: Int {
        20
    }

    /// The user's custom rows, decoded from the JSON `HomeView` keeps in
    /// @AppStorage.
    var customSections: [CustomHomeSection] {
        CustomHomeSections.decode(customSectionsRaw)
    }

    /// Identity of the custom-section load. Shares the trending key's playlist /
    /// sync / visibility inputs — the match is against the same catalog — plus a
    /// signature of the sections themselves, so adding a row or editing its URL
    /// reloads while renaming one doesn't.
    var customSectionsKey: String {
        "custom-\(trendingKey)-\(CustomHomeSections.contentSignature(visibleCustomSections))"
    }

    /// The custom sections that should actually be fetched: the user's list
    /// minus the ones they've hidden. A hidden row costs no network.
    var visibleCustomSections: [CustomHomeSection] {
        customSections.filter {
            HomeLayoutSettings.isEnabled(.custom($0.id), disabledRaw: disabledSectionsRaw)
        }
    }

    /// Fetches every visible custom list concurrently, then matches each one
    /// against the local catalog on the main context. The fetches are the slow
    /// part and are independent; the matching is two batched queries per section
    /// and stays on the main actor with the rest of Home's model access.
    func loadCustomSections(cacheKey: String) async {
        let sections = visibleCustomSections
        guard !sections.isEmpty else {
            customSectionItems = [:]
            return
        }
        if let cached = HomeTrendingCache.shared.customEntry(for: cacheKey) {
            customSectionItems = cached
            return
        }

        let interval = Perf.begin(.homeCustomSections)
        defer { Perf.end(interval) }

        let lists = await withTaskGroup(of: (UUID, [HomeListEntry]?).self) { group in
            for section in sections {
                group.addTask {
                    // A failed fetch is nil, not an empty list — the two are
                    // handled differently below.
                    await (section.id, try? HomeListCatalog.entries(for: section.sourceURL))
                }
            }
            var results: [UUID: [HomeListEntry]?] = [:]
            for await (id, entries) in group {
                results[id] = entries
            }
            return results
        }

        var matched: [UUID: [HomeMediaItem]] = [:]
        for section in sections {
            matched[section.id] = match(entries: (lists[section.id] ?? nil) ?? [])
        }
        customSectionItems = matched

        // Only memo a complete pass. Caching a row that failed to load (offline
        // at launch, provider down) would leave it empty for the whole session,
        // since the cache key doesn't change until the catalog or the sections do.
        guard sections.allSatisfy({ (lists[$0.id] ?? nil) != nil }) else { return }
        HomeTrendingCache.shared.storeCustom(key: cacheKey, items: matched)
    }

    /// Resolves list entries to local models, preserving the list's own order
    /// and dropping anything the active playlist doesn't carry.
    private func match(entries: [HomeListEntry]) -> [HomeMediaItem] {
        guard !entries.isEmpty else { return [] }
        let moviesByTmdbId = fetchMovies(tmdbIds: entries.filter { $0.mediaType == .movie }.map(\.tmdbId))
        let seriesByTmdbId = fetchSeries(tmdbIds: entries.filter { $0.mediaType == .series }.map(\.tmdbId))

        var items: [HomeMediaItem] = []
        var seen = Set<String>()
        for entry in entries {
            let item: HomeMediaItem? = switch entry.mediaType {
            case .movie: moviesByTmdbId[entry.tmdbId].map(HomeMediaItem.movie)
            case .series: seriesByTmdbId[entry.tmdbId].map(HomeMediaItem.series)
            }
            // A list can name the same title twice (or a title can sit in the
            // catalog under two ids); keep the first placement.
            guard let item, seen.insert(item.id).inserted else { continue }
            items.append(item)
            if items.count >= HomeView.customSectionItemLimit { break }
        }
        return items
    }
}
