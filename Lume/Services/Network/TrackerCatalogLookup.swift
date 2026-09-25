//
//  TrackerCatalogLookup.swift
//  Lume
//
//  The catalog rows a tracker's watched-history import applies to.
//

import Foundation
import SwiftData

/// Fetches only the catalog rows whose TMDB id a tracker reported, rather
/// than every row with a TMDB id and intersecting in memory — a large catalog
/// holds far more titles than any watched history.
///
/// The ids go into the predicate as chunked `IN` lists, kept comfortably under
/// SQLite's bound-variable cap for a long history.
enum TrackerCatalogLookup {
    private static let idChunkSize = 500

    static func movies(tmdbIDs: Set<Int>, in context: ModelContext) -> [Movie] {
        chunks(of: tmdbIDs).flatMap { chunk in
            (try? context.fetch(FetchDescriptor(predicate: movieTmdbIdPredicate(ids: chunk)))) ?? []
        }
    }

    static func series(tmdbIDs: Set<Int>, in context: ModelContext) -> [Series] {
        chunks(of: tmdbIDs).flatMap { chunk in
            (try? context.fetch(FetchDescriptor(predicate: seriesTmdbIdPredicate(ids: chunk)))) ?? []
        }
    }

    private static func chunks(of ids: Set<Int>) -> [Set<Int>] {
        let sorted = ids.sorted()
        return stride(from: 0, to: sorted.count, by: idChunkSize).map {
            Set(sorted[$0 ..< min($0 + idChunkSize, sorted.count)])
        }
    }
}
