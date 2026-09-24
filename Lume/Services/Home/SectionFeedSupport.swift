//
//  SectionFeedSupport.swift
//  Lume
//
//  Small shared types and SQL-safe predicates used by SectionFeed and its
//  collection resolver.
//

import Foundation
import SwiftData

enum HomeLoadState {
    case idle
    case loading
    /// A previously resolved collection is visible while its source is being
    /// revalidated or its hero artwork is being refreshed.
    case cached
    case loaded
    case failed

    var isSettled: Bool {
        switch self {
        case .idle, .loading, .cached: false
        case .loaded, .failed: true
        }
    }
}

/// What the promoted section can render right now. This is deliberately
/// separate from a row's network state: a list can load successfully but still
/// resolve to no local titles, or none of its titles may have usable wide art.
enum HeroLoadState: Equatable {
    case disabled
    case loading
    case content
    case empty
    case failed

    /// Loading keeps the first-frame geometry stable. Empty and failed are
    /// terminal and release the reserved space instead of leaving a blank hero.
    var reservesSpace: Bool {
        switch self {
        case .loading, .content: true
        case .disabled, .empty, .failed: false
        }
    }
}

/// `tmdbId` is optional, and neither `?? -1` (TERNARY) nor a nil-check +
/// force-unwrap (ForcedUnwrap) survives SwiftData's SQL generation — both throw
/// at fetch time on a real store (in-memory stores skip SQL and don't
/// reproduce it). Comparing against a `Set<Int?>` builds a plain `IN` clause.
/// Internal (not fileprivate) so tests can run them against a SQLite store.
nonisolated func movieTmdbIdPredicate(ids: Set<Int>) -> Predicate<Movie> {
    let optionalIds = Set(ids.map(Int?.some))
    return #Predicate { optionalIds.contains($0.tmdbId) }
}

nonisolated func seriesTmdbIdPredicate(ids: Set<Int>) -> Predicate<Series> {
    let optionalIds = Set(ids.map(Int?.some))
    return #Predicate { optionalIds.contains($0.tmdbId) }
}
