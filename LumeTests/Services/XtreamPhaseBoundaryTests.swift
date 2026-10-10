import Foundation
@testable import Lume
import SwiftData
import Testing

@Suite(.readsGlobalState)
struct XtreamPhaseBoundaryTests {
    private enum Failure: Error { case rejectedBatch }

    @Test(arguments: [false, true])
    func `a failed or cancelled final batch does not sweep or certify the import`(cancel: Bool) async throws {
        let container = try makeTestContainer()
        let playlistId = UUID()
        let staleID = "\(playlistId.uuidString)-movie-stale"
        let seed = ModelContext(container)
        seed.insert(Movie(id: staleID, streamId: 99, name: "Keep on failure"))
        try seed.save()
        XtreamDigestStore.store(.init(digest: "previous-success", rowCount: 1), playlistId: playlistId, endpoint: .movies)
        defer { XtreamDigestStore.removeAll(playlistId: playlistId) }
        let manager = ContentSyncManager(modelContainer: container)
        let task = Task {
            try await manager.runXtreamContentPhase(.movies, playlistId: playlistId, progress: nil, reuseUnchanged: false,
                                                    fetch: { _ in .fetched(Array(0 ... 2000), digest: "test-digest",
                                                                           validator: .init(etag: "new-etag", requestIdentity: "request")) },
                                                    upsert: { batch, context in
                                                        if batch.startIndex == 2000 {
                                                            if cancel { withUnsafeCurrentTask { $0?.cancel() } } else { throw Failure.rejectedBatch }
                                                        }
                                                        // Already saved batches intentionally survive failure.
                                                        let id = "\(playlistId.uuidString)-movie-\(batch.startIndex)"
                                                        context.insert(Movie(id: id, streamId: batch.startIndex, name: "Imported"))
                                                        return [id]
                                                    })
        }
        do {
            try await task.value
            Issue.record("An interrupted phase must throw")
        } catch {
            #expect(cancel ? error is CancellationError : error is Failure)
        }
        let check = ModelContext(container)
        #expect(try check.fetch(FetchDescriptor<Movie>()).contains { $0.id == staleID })
        #expect(try check.fetchCount(FetchDescriptor<Movie>()) >= 2)
        #expect(XtreamDigestStore.entry(playlistId: playlistId, endpoint: .movies) == nil)
    }
}
