import SwiftData
import SwiftUI

/// Series alone observes a one-row watch stamp and owns episode resume lookup.
/// The common library surface does not add this query to Movies.
struct SeriesView: View {
    @Environment(\.contentRestriction) private var restriction
    @State private var resumeLoader = SeriesResumeLoadMachine()
    @Query private var newestWatchedSeries: [Series]
    private let queryPrefix: String?

    init(playlistPrefix: String? = nil, restriction: ContentRestriction = ContentRestriction()) {
        queryPrefix = playlistPrefix
        var descriptor = HomeQuery.watchedSeries(playlistPrefix: playlistPrefix ?? "", excludedCategoryIDs: restriction.excludedCategoryIDs)
        descriptor.fetchLimit = 1
        _newestWatchedSeries = Query(descriptor)
    }

    var body: some View {
        LibraryAreaView<SeriesCatalog>(playlistPrefix: queryPrefix, restriction: restriction,
                                       resumeLoader: resumeLoader, watchedSeries: newestWatchedSeries)
    }
}

#Preview("Empty") {
    SeriesView()
        .modelContainer(for: Playlist.self, inMemory: true)
}

#Preview("With Data") {
    SeriesView()
        .modelContainer(previewContainer())
}
