import Foundation
@testable import Lume
import SwiftData
import XCTest

/// Matched on-disk batches: the pre-refactor loop versus the production helper,
/// with identical fields/transactions. No network, Debug timings or in-memory store.
final class CatalogUpsertBenchmarks: XCTestCase {
    func testLegacyColdMovieBatches() throws {
        try measureBatches(shared: false, warm: false)
    }

    func testSharedColdMovieBatches() throws {
        try measureBatches(shared: true, warm: false)
    }

    func testLegacyUnchangedMovieBatches() throws {
        try measureBatches(shared: false, warm: true)
    }

    func testSharedUnchangedMovieBatches() throws {
        try measureBatches(shared: true, warm: true)
    }

    private func measureBatches(shared: Bool, warm: Bool) throws {
        let store = try PerfStore.makeOnDiskContainer()
        defer { PerfStore.destroy(directory: store.directory) }
        let playlistId = UUID()
        if warm { try importMovies(container: store.container, playlistId: playlistId, shared: false) }
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            do {
                // A unique namespace gives each cold iteration a fresh catalog
                // without timing store creation or deletion.
                let id = warm ? playlistId : UUID()
                startMeasuring()
                try importMovies(container: store.container, playlistId: id, shared: shared)
                stopMeasuring()
            } catch { XCTFail("Import failed: \(error)") }
        }
    }

    private func importMovies(container: ModelContainer, playlistId: UUID, shared: Bool) throws {
        for start in stride(from: 0, to: 20000, by: 2000) {
            try autoreleasepool {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                let batch = start ..< min(start + 2000, 20000)
                if shared {
                    _ = try CatalogUpsert.batch(batch, context: context,
                                                identity: { CatalogID.content(playlistId, kind: .movie, key: $0) },
                                                create: { Movie(id: $1, streamId: $0, name: "") },
                                                apply: { applyFields(index: $0, to: $1, playlistId: playlistId) })
                } else {
                    let ids = batch.map { "\(playlistId.uuidString)-movie-\($0)" }
                    var existing: [String: Movie] = [:]
                    existing.reserveCapacity(ids.count)
                    for row in try context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { ids.contains($0.id) })) {
                        existing[row.id] = row
                    }
                    for index in batch {
                        let id = "\(playlistId.uuidString)-movie-\(index)"
                        let movie: Movie
                        if let found = existing[id] { movie = found } else {
                            movie = Movie(id: id, streamId: index, name: "")
                            context.insert(movie)
                        }
                        applyFields(index: index, to: movie, playlistId: playlistId)
                    }
                }
                if context.hasChanges { try context.save() }
            }
        }
    }

    private func applyFields(index: Int, to movie: Movie, playlistId: UUID) {
        let name = "Movie \(index)"
        if movie.name != name { movie.name = name }
        let icon = "https://example.invalid/\(index).jpg"
        if movie.streamIcon != icon { movie.streamIcon = icon }
        let categoryId = "\(playlistId.uuidString)-vod-\(index % 300)"
        if movie.categoryId != categoryId { movie.categoryId = categoryId }
        let rating = Double(index % 10)
        if movie.rating != rating { movie.rating = rating }
    }
}
