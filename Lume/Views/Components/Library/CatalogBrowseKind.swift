import SwiftData
import SwiftUI

/// Concrete SQL/card adapters for a shared browse lifecycle. Predicates stay
/// concrete: SwiftData must see Movie/Series key paths, not erased models.
@MainActor
protocol CatalogBrowseKind {
    associatedtype Item: PersistentModel & Hashable & WatchlistFavoritable
    associatedtype Card: View
    static var categoryType: CategoryType { get }
    static var surface: SectionSurface { get }
    static var emptyTitle: LocalizedStringKey { get }
    static var emptyIcon: String { get }
    static var categoryEmptyDescription: LocalizedStringKey { get }
    static var genreEmptyDescription: LocalizedStringKey { get }
    static func categoryDescriptor(id: String) -> FetchDescriptor<Item>
    static func card(_ item: Item, fillsWidth: Bool) -> Card
    nonisolated static func genrePage(container: ModelContainer, request: GenrePageRequest) -> GenrePage
    static func genres(in container: ModelContainer, prefix: String, restriction: ContentRestriction) async -> [String]
}

extension CatalogBrowseKind {
    static func categoryPage(in context: ModelContext, id: String, offset: Int, limit: Int) throws -> [Item] {
        var descriptor = categoryDescriptor(id: id)
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }
}

enum MovieCatalog: CatalogBrowseKind {
    static let categoryType = CategoryType.vod
    static let surface = SectionSurface.movies
    static let emptyTitle: LocalizedStringKey = "No Movies"
    static let emptyIcon = "film.stack"
    static let categoryEmptyDescription: LocalizedStringKey = "This category has no movies"
    static let genreEmptyDescription: LocalizedStringKey = "No movies in this genre"

    static func categoryDescriptor(id: String) -> FetchDescriptor<Movie> {
        FetchDescriptor(predicate: #Predicate<Movie> { $0.categoryId == id }, sortBy: ContentSortOption.playlist.movieDescriptors)
    }

    static func card(_ item: Movie, fillsWidth: Bool) -> MovieCardView {
        MovieCardView(movie: item, fillsWidth: fillsWidth)
    }

    nonisolated static func genrePage(container: ModelContainer, request: GenrePageRequest) -> GenrePage {
        GenrePageFetcher.movies(container: container, request: request, sortBy: ContentSortOption.playlist.movieDescriptors)
    }

    static func genres(in container: ModelContainer, prefix: String, restriction: ContentRestriction) async -> [String] {
        await GenreDerivation.movieGenres(in: container, playlistPrefix: prefix, restriction: restriction)
    }
}

enum SeriesCatalog: CatalogBrowseKind {
    static let categoryType = CategoryType.series
    static let surface = SectionSurface.series
    static let emptyTitle: LocalizedStringKey = "No Series"
    static let emptyIcon = "tv.fill"
    static let categoryEmptyDescription: LocalizedStringKey = "This category has no series"
    static let genreEmptyDescription: LocalizedStringKey = "No series in this genre"

    static func categoryDescriptor(id: String) -> FetchDescriptor<Series> {
        FetchDescriptor(predicate: #Predicate<Series> { $0.categoryId == id }, sortBy: ContentSortOption.playlist.seriesDescriptors)
    }

    static func card(_ item: Series, fillsWidth: Bool) -> SeriesCardView {
        SeriesCardView(series: item, fillsWidth: fillsWidth)
    }

    nonisolated static func genrePage(container: ModelContainer, request: GenrePageRequest) -> GenrePage {
        GenrePageFetcher.series(container: container, request: request, sortBy: ContentSortOption.playlist.seriesDescriptors)
    }

    static func genres(in container: ModelContainer, prefix: String, restriction: ContentRestriction) async -> [String] {
        await GenreDerivation.seriesGenres(in: container, playlistPrefix: prefix, restriction: restriction)
    }
}
