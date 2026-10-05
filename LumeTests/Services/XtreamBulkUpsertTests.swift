import Foundation
@testable import Lume
import SwiftData
import Testing

@Suite(.readsGlobalState)
struct XtreamBulkUpsertTests {
    @Test(arguments: ["get_vod_streams", "get_series", "get_live_streams"])
    func `duplicates across batches retain user state and apply the last provider fields`(action: String) async throws {
        let container = try makeTestContainer()
        let host = "xtream-upsert-\(UUID().uuidString.lowercased()).test"
        let playlist = Playlist(name: "Duplicates", serverURL: "http://\(host)", username: "u", password: "p")
        defer { XtreamDigestStore.removeAll(playlistId: playlist.id) }
        let context = ModelContext(container)
        context.insert(playlist)
        let movie = Movie(id: "\(playlist.id)-movie-1", streamId: 1, name: "Stored")
        let series = Series(id: "\(playlist.id)-series-1", seriesId: 1, name: "Stored")
        let live = LiveStream(id: "\(playlist.id)-live-1", streamId: 1, name: "Stored")
        context.insert(movie)
        context.insert(series)
        context.insert(live)
        movie.isFavorite = true
        movie.watchProgress = 50
        movie.posterPath = "/enriched.jpg"
        series.isFavorite = true
        series.posterPath = "/enriched.jpg"
        live.isFavorite = true
        try context.save()
        let idKey = action == "get_series" ? "series_id" : "stream_id"
        let row = "{\"\(idKey)\":1,\"name\":\"First\"}"
        // One repeated identity in and across the real 2,000-row batch boundary.
        let payload = "[" + (Array(repeating: row, count: 2000) + ["{\"\(idKey)\":1,\"name\":\"Last\"}", "{\"name\":\"No identity\"}"]).joined(separator: ",") + "]"
        StubURLProtocol.register(host: host, query: ("action", action), response: .init(body: payload))
        let manager = ContentSyncManager(modelContainer: container, xtreamClient: XtreamClient(urlSession: StubURLProtocol.makeSession()))
        switch action {
        case "get_vod_streams": try await manager.syncMovies(for: playlist, playlistId: playlist.id)
        case "get_series": try await manager.syncSeries(for: playlist, playlistId: playlist.id)
        default: try await manager.syncLiveStreams(for: playlist, playlistId: playlist.id)
        }
        let check = ModelContext(container)
        let checkedMovie = try #require(try check.fetch(FetchDescriptor<Movie>()).first)
        let checkedSeries = try #require(try check.fetch(FetchDescriptor<Series>()).first)
        let checkedLive = try #require(try check.fetch(FetchDescriptor<LiveStream>()).first)
        #expect(try check.fetchCount(FetchDescriptor<Movie>()) == 1)
        #expect(try check.fetchCount(FetchDescriptor<Series>()) == 1)
        #expect(try check.fetchCount(FetchDescriptor<LiveStream>()) == 1)
        #expect(checkedMovie.name == (action == "get_vod_streams" ? "Last" : "Stored"))
        #expect(checkedSeries.name == (action == "get_series" ? "Last" : "Stored"))
        #expect(checkedLive.name == (action == "get_live_streams" ? "Last" : "Stored"))
        #expect(checkedMovie.isFavorite && checkedMovie.watchProgress == 50 && checkedMovie.posterPath == "/enriched.jpg")
        #expect(checkedSeries.isFavorite && checkedSeries.posterPath == "/enriched.jpg")
        #expect(checkedLive.isFavorite)
    }
}
