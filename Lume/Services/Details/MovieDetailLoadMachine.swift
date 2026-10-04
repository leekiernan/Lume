import Observation
import SwiftData

/// One per detail presentation. Models stay on the view's actor/context; layout,
/// focus, playback, and user mutations remain in the platform view.
@Observable
final class MovieDetailLoadMachine {
    struct Snapshot {
        var isLoadingTMDB: Bool
        var similar: [HomeMediaItem] = []
        var collectionMovies: [HomeMediaItem] = []
        var otherSources: [OtherSources.Source] = []
    }

    private(set) var contentID: String
    private var detail: DetailLoadState
    private var collection = DetailLoadState()
    private(set) var collectionID: Int?
    private(set) var similar: [HomeMediaItem] = []
    private(set) var collectionMovies: [HomeMediaItem] = []
    private(set) var otherSources: [OtherSources.Source] = []

    var isLoadingTMDB: Bool {
        detail.isBlocking
    }

    init(movie: Movie) {
        contentID = movie.id
        detail = Self.initialDetail(for: movie)
    }

    /// Safe before the view's identity-keyed task prepares a replacement title.
    /// A changed collection also hides the old lane before its next load starts.
    func snapshot(for movie: Movie) -> Snapshot {
        guard contentID == movie.id else {
            return Snapshot(isLoadingTMDB: Self.initialDetail(for: movie).isBlocking)
        }
        return Snapshot(
            isLoadingTMDB: isLoadingTMDB, similar: similar,
            collectionMovies: collectionID == movie.collectionId ? collectionMovies : [],
            otherSources: otherSources
        )
    }

    func load(_ movie: Movie, in context: ModelContext) async {
        prepare(movie)
        let request = detail.begin()
        await enrichMovieDetailsIfNeeded(movie, context: context)
        guard !Task.isCancelled, detail.owns(request) else { return }
        await enrichMovieRatingsIfNeeded(movie, context: context)
        guard !Task.isCancelled, detail.owns(request) else { return }
        resolveSimilar(movie, in: context)
        otherSources = OtherSources.resolve(for: movie, in: context)
        detail.finish(request)
    }

    func resolveSimilar(_ movie: Movie, in context: ModelContext) {
        prepare(movie)
        similar = RelatedTitlesResolver.similar(to: movie, in: context)
    }

    func loadCollection(_ movie: Movie, in context: ModelContext) async {
        prepare(movie)
        let request = collection.begin()
        if collectionID != movie.collectionId { collectionMovies = [] }
        collectionID = movie.collectionId
        guard let id = movie.collectionId else {
            collectionMovies = []
            collection.finish(request)
            return
        }
        let manager = ContentSyncManager(modelContainer: context.container)
        do {
            let ids = try await manager.fetchTMDBCollectionMovieIDs(collectionId: id)
            guard !Task.isCancelled, collection.owns(request), movie.collectionId == id else { return }
            collectionMovies = RelatedTitlesResolver.collectionParts(ids, of: movie, in: context)
            collection.finish(request)
        } catch {
            guard !Task.isCancelled, collection.owns(request), movie.collectionId == id else { return }
            collectionMovies = []
            collection.finish(request)
        }
    }

    func invalidate() {
        detail.invalidate()
        collection.invalidate()
    }

    private func prepare(_ movie: Movie) {
        guard contentID != movie.id else { return }
        invalidate()
        contentID = movie.id
        similar = []
        collectionMovies = []
        collectionID = nil
        otherSources = []
        detail = Self.initialDetail(for: movie)
    }

    private static func initialDetail(for movie: Movie) -> DetailLoadState {
        DetailLoadState(isBlocking: detailNeedsTMDBFetch(tmdbId: movie.tmdbId, enrichedAt: movie.tmdbEnrichedAt))
    }
}
