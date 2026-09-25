import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct TrackerCatalogLookupTests {
    @Test func `fetches only the reported ids across several chunks`() throws {
        let context = try ModelContext(makeTestContainer())
        for index in 0 ..< 1200 {
            let movie = Movie(id: "m-\(index)", streamId: index, name: "Movie \(index)")
            movie.tmdbId = index
            context.insert(movie)
        }
        let untracked = Movie(id: "m-none", streamId: 9999, name: "No TMDB")
        context.insert(untracked)
        try context.save()

        // Every other id, so the lookup spans more than one `IN` chunk.
        let wanted = Set(stride(from: 0, to: 1200, by: 2))
        let movies = TrackerCatalogLookup.movies(tmdbIDs: wanted, in: context)

        #expect(Set(movies.compactMap(\.tmdbId)) == wanted)
        #expect(movies.count == wanted.count)
    }

    @Test func `no ids fetches nothing`() throws {
        let context = try ModelContext(makeTestContainer())
        #expect(TrackerCatalogLookup.series(tmdbIDs: [], in: context).isEmpty)
    }
}
