import SwiftUI

/// One route policy for Home and the movie/series libraries. Keep concrete
/// model destinations so poster links, hero buttons and deep links agree.
enum MediaDetailNavigation {
    static func pathBinding(
        in router: DeepLinkRouter?,
        at path: ReferenceWritableKeyPath<DeepLinkRouter, NavigationPath>,
        fallback: Binding<NavigationPath>
    ) -> Binding<NavigationPath> {
        guard let router else { return fallback }
        return Binding(get: { router[keyPath: path] }, set: { router[keyPath: path] = $0 })
    }

    static func appending(_ hero: HeroItem, to path: NavigationPath) -> NavigationPath {
        var path = path
        switch hero {
        case let .movie(movie, _, _, _, _): path.append(movie)
        case let .series(series, _, _, _, _): path.append(series)
        }
        return path
    }
}

extension View {
    /// Install inside the area's NavigationStack. A restored value route uses
    /// the same detail screen and platform transition as a new poster push.
    func mediaDetailDestinations(namespace: Namespace.ID) -> some View {
        modifier(MediaDetailDestinations(namespace: namespace))
    }
}

private struct MediaDetailDestinations: ViewModifier {
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: Movie.self) { movie in
                MovieDetailView(movie: movie, animationNamespace: namespace)
                #if os(iOS)
                    .navigationTransition(.zoom(sourceID: movie.id, in: namespace))
                #endif
            }
            .navigationDestination(for: Series.self) { series in
                SeriesDetailView(series: series, animationNamespace: namespace)
                #if os(iOS)
                    .navigationTransition(.zoom(sourceID: series.id, in: namespace))
                #endif
            }
    }
}
