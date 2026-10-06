//
//  HomeRows.swift
//  Lume
//
//  The horizontal rails on the Home screen (Recently Watched, Trending, etc.)
//  and the poster cards they contain. Extracted from `HomeView` to keep that
//  file focused on data loading and screen composition.
//

import SwiftData
import SwiftUI

// MARK: - Row

struct HomeRow: View {
    /// A `Text` rather than a `LocalizedStringKey` so custom rows can pass their
    /// user-typed header verbatim while the built-in rows stay localized.
    let title: Text
    let items: [HomeMediaItem]
    /// Resume fractions keyed by series id, resolved once for the whole screen
    /// (`SeriesResumeLoader`) rather than per card — see `HomeMediaItem`.
    let seriesResume: [String: Double]
    let onPlayLive: (LiveStream) -> Void
    /// Destination for remote rows whose retained source contains more than the
    /// 20-card preview. Local rows supply their own collection navigation.
    var showAll: SectionCollectionSelection?
    /// When set, each card gains a "Remove from Recently Watched" context menu.
    /// Only the Recently Watched row passes this; the others leave it nil.
    var onRemove: ((HomeMediaItem) -> Void)?
    /// When set, each card gains up/down vote actions. Only the "For You" row
    /// passes this; the others leave it nil.
    var onVote: ((HomeMediaItem, RecommendationVote) -> Void)?
    /// Seeds Multi-View from a channel card's long-press menu.
    var onStartMultiView: ((LiveStream) -> Void)?
    /// tvOS: pressing left on the row's first card. The Movies/Series pages use
    /// it to reveal the browse sidebar; Home leaves it nil.
    var onLeadingLeft: (() -> Void)?
    var animationNamespace: Namespace.ID?

    var body: some View {
        PosterRail(title: title, showAll: showAll) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HomeItemCell(
                    item: item,
                    seriesResume: seriesResume,
                    onPlayLive: onPlayLive,
                    onRemove: onRemove,
                    onVote: onVote,
                    onStartMultiView: onStartMultiView,
                    animationNamespace: animationNamespace
                )
                .onLeadingEdgeLeft(index == 0 ? onLeadingLeft : nil)
            }
        }
    }
}

private struct HomeItemCell: View {
    let item: HomeMediaItem
    let seriesResume: [String: Double]
    let onPlayLive: (LiveStream) -> Void
    var onRemove: ((HomeMediaItem) -> Void)?
    var onVote: ((HomeMediaItem, RecommendationVote) -> Void)?
    var onStartMultiView: ((LiveStream) -> Void)?
    var animationNamespace: Namespace.ID?

    var body: some View {
        Group {
            switch item {
            case let .movie(movie):
                NavigationLink(value: movie) {
                    PosterCard(title: item.title, provider: item.imageURL?.absoluteString, posterPath: movie.posterPath,
                               request: .init(kind: .movie, id: movie.id, categoryID: movie.categoryId), progress: progress)
                        .matchedTransitionSourceIfAvailable(id: movie.id, in: animationNamespace)
                }
                .posterCardButtonStyle()
            case let .series(series):
                NavigationLink(value: series) {
                    PosterCard(
                        title: item.title, provider: item.imageURL?.absoluteString, posterPath: series.posterPath,
                        request: .init(kind: .series, id: series.id, categoryID: series.categoryId), progress: progress
                    )
                    .matchedTransitionSourceIfAvailable(id: series.id, in: animationNamespace)
                }
                .posterCardButtonStyle()
            case let .live(stream):
                Button {
                    onPlayLive(stream)
                } label: {
                    HomeLiveLogoCard(title: item.title, imageURL: item.imageURL)
                }
                .posterCardButtonStyle()
            }
        }
        .modifier(HomeItemMenu(
            item: item,
            onRemove: onRemove,
            onVote: onVote,
            onStartMultiView: onStartMultiView
        ))
    }

    private var progress: Double? {
        item.progress(seriesResume: seriesResume)
    }
}

/// The card's long-press menu. A channel gets the full channel menu — the same
/// one its row in Live TV carries, and the live favorite semantic (the flag
/// alone, no watchlist date) — while a movie or series gets the VOD one. Every
/// action a card offers is built here, in a single menu: only the outermost
/// `contextMenu` on a view survives, so a stacked second modifier would silently
/// replace the first.
struct HomeItemMenu: ViewModifier {
    let item: HomeMediaItem
    let onRemove: ((HomeMediaItem) -> Void)?
    let onVote: ((HomeMediaItem, RecommendationVote) -> Void)?
    let onStartMultiView: ((LiveStream) -> Void)?
    @Environment(\.modelContext) private var modelContext

    func body(content: Content) -> some View {
        let removeFromRecents = onRemove.map { action in { action(item) } }
        let voteAction = onVote.map { action in { (vote: RecommendationVote) in action(item, vote) } }

        switch item {
        case let .live(stream):
            content.liveChannelMenu(
                isFavorite: stream.isFavorite,
                onToggleFavorite: { LiveChannelFavorites.toggle(stream, in: modelContext) },
                onStartMultiView: onStartMultiView.map { action in { action(stream) } },
                onRemoveFromRecents: removeFromRecents
            )
        default:
            content.mediaFavoriteMenu(
                item,
                in: modelContext,
                onRemoveFromRecents: removeFromRecents,
                onVote: voteAction
            )
        }
    }
}

// MARK: - For You row

/// The "For You" rail. Unlike the other rows it always renders when
/// recommendations are enabled: while the first list is still being computed it
/// shows a progress placeholder, and when there's nothing to suggest yet it
/// nudges the user toward the actions that seed recommendations.
struct ForYouRow: View {
    let items: [HomeMediaItem]
    let seriesResume: [String: Double]
    let isLoading: Bool
    let onPlayLive: (LiveStream) -> Void
    let onVote: (HomeMediaItem, RecommendationVote) -> Void
    var animationNamespace: Namespace.ID?

    var body: some View {
        if items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("For You")
                    .font(PosterCardMetrics.railTitleFont)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                    .padding(.horizontal)
                placeholder
                    .padding(.horizontal)
            }
        } else {
            HomeRow(
                title: Text("For You"),
                items: items,
                seriesResume: seriesResume,
                onPlayLive: onPlayLive,
                onVote: onVote,
                animationNamespace: animationNamespace
            )
        }
    }

    private var placeholder: some View {
        HStack(spacing: 12) {
            if isLoading {
                ProgressView()
                Text("Finding recommendations…")
            } else {
                Image(systemName: "sparkles")
                Text("Watch, favorite, or rate titles and we'll suggest more here.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Poster card

/// The channel-logo card used by Home rails. VOD posters and resume treatment
/// are provided separately by `PosterCard`.
///
/// Live channel logos are mostly transparent PNGs, so unlike movie/series
/// posters they can't fill the card themselves. They get a full card treatment
/// instead: a neutral dark gradient plate (consistent next to poster artwork in
/// any color scheme) and an inset so the logo never touches the edges.
private struct HomeLiveLogoCard: View {
    let title: String
    let imageURL: URL?

    var body: some View {
        CachedAsyncImage(url: imageURL, maxPixelSize: PosterCardMetrics.posterHeight, content: artworkContent)
            .frame(width: PosterCardMetrics.posterWidth, height: PosterCardMetrics.posterHeight)
            .background { liveCardBackground }
            .posterArtworkFrame(fillsWidth: false)
            .clipShape(RoundedRectangle(cornerRadius: PosterCardMetrics.cornerRadius, style: .continuous))
        // Skipped on tvOS for the same reason as `MovieCardView`: a shadow
        // after clipShape costs an offscreen pass per card and is invisible
        // at 10 feet.
        #if !os(tvOS)
            .shadow(radius: 2)
        #endif
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
    }

    /// Like a poster, the logo stands alone once it loads; until then — or
    /// without one — the channel's name sits on the plate.
    @ViewBuilder
    private func artworkContent(_ phase: AsyncImagePhase) -> some View {
        switch phase {
        case let .success(image):
            image.resizable().aspectRatio(contentMode: .fit)
                .padding(PosterCardMetrics.liveLogoInset)
        case .empty, .failure:
            Text(title)
                .font(PosterCardMetrics.tileTitleFont)
                .foregroundStyle(.white)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .padding(PosterCardMetrics.tileInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        @unknown default:
            EmptyView()
        }
    }

    /// The plate behind transparent channel logos. Fixed dark grays (not
    /// scheme-adaptive) so the card reads the same on the tvOS backdrop and in
    /// iOS/macOS light mode.
    private var liveCardBackground: some View {
        LinearGradient(
            colors: [Color(white: 0.30), Color(white: 0.14)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
