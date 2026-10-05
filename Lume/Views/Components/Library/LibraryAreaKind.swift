import SwiftUI

/// Typed destinations and collection query owners for a VOD library surface.
/// No AnyView, erased models, or universal media predicate is involved.
@MainActor
protocol LibraryAreaKind: CatalogBrowseKind {
    associatedtype Detail: View
    associatedtype CollectionRow: View
    associatedtype CollectionPage: View
    static var navigationPath: ReferenceWritableKeyPath<DeepLinkRouter, NavigationPath> { get }
    static var playlistEmptyIcon: String { get }
    static var playlistEmptyDescription: LocalizedStringKey { get }
    static var libraryEmptyDescription: LocalizedStringKey { get }
    static func heroItem(_ hero: HeroItem) -> Item?
    static func detail(_ item: Item, namespace: Namespace.ID) -> Detail
    static func collectionRow(_ kind: LibraryCollection.Kind, prefix: String, excluded: Set<String>, namespace: Namespace.ID, onLeadingLeft: @escaping () -> Void) -> CollectionRow
    static func collectionPage(_ kind: LibraryCollection.Kind, prefix: String, namespace: Namespace.ID) -> CollectionPage
}

extension LibraryAreaKind {
    static func pathBinding(in router: DeepLinkRouter) -> Binding<NavigationPath> {
        Binding(get: { router[keyPath: navigationPath] }, set: { router[keyPath: navigationPath] = $0 })
    }
}

extension MovieCatalog: LibraryAreaKind {
    static var navigationPath: ReferenceWritableKeyPath<DeepLinkRouter, NavigationPath> {
        \.moviesPath
    }

    static let playlistEmptyIcon = "film.stack"
    static let playlistEmptyDescription: LocalizedStringKey = "Add a playlist in Settings to start browsing movies"
    static let libraryEmptyDescription: LocalizedStringKey = "Sync your playlist to load movies"

    static func heroItem(_ hero: HeroItem) -> Movie? {
        hero.movie
    }

    static func detail(_ item: Movie, namespace: Namespace.ID) -> MovieDetailView {
        MovieDetailView(movie: item, animationNamespace: namespace)
    }

    static func collectionRow(_ kind: LibraryCollection.Kind, prefix: String, excluded: Set<String>, namespace: Namespace.ID, onLeadingLeft: @escaping () -> Void) -> MovieCollectionRow {
        MovieCollectionRow(kind: kind, playlistPrefix: prefix, excludedCategoryIDs: excluded, animationNamespace: namespace, onLeadingLeft: onLeadingLeft)
    }

    static func collectionPage(_ kind: LibraryCollection.Kind, prefix: String, namespace: Namespace.ID) -> MovieCollectionView {
        MovieCollectionView(kind: kind, playlistPrefix: prefix, animationNamespace: namespace)
    }
}

extension SeriesCatalog: LibraryAreaKind {
    static var navigationPath: ReferenceWritableKeyPath<DeepLinkRouter, NavigationPath> {
        \.seriesPath
    }

    static let playlistEmptyIcon = "tv"
    static let playlistEmptyDescription: LocalizedStringKey = "Add a playlist in Settings to start browsing series"
    static let libraryEmptyDescription: LocalizedStringKey = "Sync your playlist to load TV series"

    static func heroItem(_ hero: HeroItem) -> Series? {
        hero.series
    }

    static func detail(_ item: Series, namespace: Namespace.ID) -> SeriesDetailView {
        SeriesDetailView(series: item, animationNamespace: namespace)
    }

    static func collectionRow(_ kind: LibraryCollection.Kind, prefix: String, excluded: Set<String>, namespace: Namespace.ID, onLeadingLeft: @escaping () -> Void) -> SeriesCollectionRow {
        SeriesCollectionRow(kind: kind, playlistPrefix: prefix, excludedCategoryIDs: excluded, animationNamespace: namespace, onLeadingLeft: onLeadingLeft)
    }

    static func collectionPage(_ kind: LibraryCollection.Kind, prefix: String, namespace: Namespace.ID) -> SeriesCollectionView {
        SeriesCollectionView(kind: kind, playlistPrefix: prefix, animationNamespace: namespace)
    }
}
