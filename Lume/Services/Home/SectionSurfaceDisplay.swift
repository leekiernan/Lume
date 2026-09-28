//
//  SectionSurfaceDisplay.swift
//  Lume
//
//  What a section surface shows, decided in one place from what it knows: the
//  playlists, every row's item count, whether the remote feed has settled, and
//  the hero's state. Pure, so each outcome is a unit test rather than a branch
//  in `body`, and every change is journalled with the counts behind it — the
//  record that separates "the rows never loaded" from "they loaded and the
//  screen didn't show them".
//

import Foundation

enum SectionSurfaceDisplay: Equatable {
    case noPlaylists
    /// Nothing to show and nothing still loading.
    case empty
    /// Rows (and possibly a hero) to show, or a feed still working on them.
    case content(hero: HeroLoadState)
}

struct SectionSurfaceSnapshot: Equatable {
    var hasPlaylists: Bool
    /// Item counts of the rows each surface queries itself (Recently Watched,
    /// Favorites…), keyed by row token.
    var localRows: [String: Int]
    /// Item counts of the feed-backed rows (trending, watchlists, custom).
    var feedRows: [String: Int]
    /// Content outside both, such as the Sports rail.
    var hasOtherContent: Bool
    var feedSettled: Bool
    var hero: HeroLoadState

    var display: SectionSurfaceDisplay {
        guard hasPlaylists else { return .noPlaylists }
        let hasRows = localRows.values.contains { $0 > 0 } || feedRows.values.contains { $0 > 0 }
        // Only call it empty once the feed has settled, so rows arriving a
        // moment later don't follow a flash of the empty state.
        if !hasRows, !hasOtherContent, feedSettled { return .empty }
        return .content(hero: hero)
    }

    /// One journal line: the decision and every count behind it.
    var logDescription: String {
        func counts(_ rows: [String: Int]) -> String {
            rows.isEmpty ? "none" : rows.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        }
        return "\(display) — local: \(counts(localRows)); feed: \(counts(feedRows)); "
            + "other: \(hasOtherContent); feed settled: \(feedSettled)"
    }
}
