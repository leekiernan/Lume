//
//  SectionFeedLoadMachine.swift
//  Lume
//
//  The load lifecycle of a section surface's remote-backed rows (TMDB trending,
//  the Trakt/Simkl watchlists, the custom list rows), as one explicit state
//  machine rather than a flag per feed.
//
//  Each source moves idle → loading/cached → loaded/failed. The surface's
//  catalog scope (playlist, visibility) is part of the machine too: a scope
//  change resets every source and hands back a reload for each one that had
//  been asked for, so a source can't be left empty just because the view task
//  that owns it happened not to re-run.
//
//  Pure: no SwiftUI, SwiftData or I/O. `SectionFeed` feeds it events, performs
//  the effects it returns and writes every transition to the diagnostic
//  journal.
//

import Foundation

/// A remote-backed feed on a section surface. Also the identity requests are
/// tracked under (`SectionFeedLoadGate`).
enum SectionFeedSource: Hashable, CustomStringConvertible {
    case trending
    case watchlist(WatchlistProvider)
    case custom

    /// The feed a row is loaded by; nil for the rows each surface queries
    /// locally (Recently Watched, Favorites, Recently Added, For You, Sports).
    init?(row: HomeSectionRef) {
        switch row {
        case .builtin(.trendingMovies), .builtin(.trendingSeries): self = .trending
        case .builtin(.traktWatchlist): self = .watchlist(.trakt)
        case .builtin(.simklWatchlist): self = .watchlist(.simkl)
        case .custom: self = .custom
        case .builtin: return nil
        }
    }

    static var allCases: [SectionFeedSource] {
        [.trending] + WatchlistProvider.allCases.map(SectionFeedSource.watchlist) + [.custom]
    }

    var description: String {
        switch self {
        case .trending: "trending"
        case let .watchlist(provider): "watchlist.\(provider)"
        case .custom: "custom"
        }
    }
}

struct SectionFeedLoadMachine: Equatable {
    /// What a load could show while it ran.
    enum CacheHit: Equatable {
        case missing
        case stale
        case fresh
    }

    enum Outcome: Equatable {
        /// Resolved — or failed while a usable cached collection stays visible.
        case loaded
        case failed
    }

    enum Event: Equatable {
        /// The catalog scope the rows are matched against (see
        /// `SectionFeed.Context`).
        case contextChanged(identity: String)
        /// A load for `source` started under `key`.
        case began(SectionFeedSource, key: String, cache: CacheHit)
        case finished(SectionFeedSource, Outcome)
        /// Rows that reached a terminal failure with nothing cached to show.
        case rowsFailed([HomeSectionRef])
        /// Rows that resolved (or are no longer asked for) since failing.
        case rowsRecovered([HomeSectionRef])
    }

    enum Effect: Equatable {
        /// Collections resolved against the previous scope must go.
        case discardCatalogModels
        /// Load `source` again under the key it was last asked for.
        case reload(SectionFeedSource, key: String)
    }

    private struct Slot: Equatable {
        var state: HomeLoadState = .idle
        var key: String?
    }

    private(set) var contextIdentity: String?
    private var slots: [SectionFeedSource: Slot] = [:]
    /// Per row rather than per source: one failed custom list must not make a
    /// successfully empty sibling look broken.
    private(set) var failedRows: Set<HomeSectionRef> = []

    func state(of source: SectionFeedSource) -> HomeLoadState {
        slots[source]?.state ?? .idle
    }

    /// True once every source has settled, so a surface can tell "still
    /// loading" from "genuinely empty".
    var isSettled: Bool {
        SectionFeedSource.allCases.allSatisfy { state(of: $0).isSettled }
    }

    /// Applies `event`, returning the effects to perform. An event that makes
    /// no sense in the current state (a load finishing that never began) leaves
    /// the state alone — `isValid` lets the caller report it.
    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case let .contextChanged(identity):
            let previous = contextIdentity
            contextIdentity = identity
            guard let previous, previous != identity else { return [] }
            failedRows.removeAll()
            var effects: [Effect] = [.discardCatalogModels]
            for source in SectionFeedSource.allCases {
                let key = slots[source]?.key
                slots[source] = Slot(state: .idle, key: key)
                if let key { effects.append(.reload(source, key: key)) }
            }
            return effects

        case let .began(source, key, cache):
            slots[source] = Slot(state: cache == .missing ? .loading : .cached, key: key)
            return []

        case let .finished(source, outcome):
            guard Self.isValid(event, in: state(of: source)) else { return [] }
            slots[source]?.state = outcome == .loaded ? .loaded : .failed
            return []

        case let .rowsFailed(rows):
            failedRows.formUnion(rows)
            return []

        case let .rowsRecovered(rows):
            failedRows.subtract(rows)
            return []
        }
    }

    /// What the promoted row can show. A hero with slides shows them; one whose
    /// source is still working holds its space; once the source settles, a row
    /// that failed — or that resolved titles but none with wide artwork — is a
    /// failed hero, and a row that resolved to nothing is an empty one.
    func heroState(for heroRef: HomeSectionRef?, hasSlides: Bool, rowHasItems: Bool) -> HeroLoadState {
        guard let heroRef else { return .disabled }
        if hasSlides { return .content }
        switch SectionFeedSource(row: heroRef).map(state(of:)) ?? .loaded {
        case .idle, .loading, .cached:
            return .loading
        case .failed:
            return .failed
        case .loaded:
            if failedRows.contains(heroRef) { return .failed }
            return rowHasItems ? .failed : .empty
        }
    }

    /// Whether `event` is a legal transition from `state`. Only a load that is
    /// running can finish.
    static func isValid(_ event: Event, in state: HomeLoadState) -> Bool {
        guard case .finished = event else { return true }
        return state == .loading || state == .cached
    }
}
