import SwiftData
import SwiftUI

typealias MoviesView = LibraryAreaView<MovieCatalog>

#Preview("Empty") {
    MoviesView()
        .modelContainer(for: Playlist.self, inMemory: true)
}

#Preview("With Data") {
    MoviesView()
        .modelContainer(previewContainer())
}
