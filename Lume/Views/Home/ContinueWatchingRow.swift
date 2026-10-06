//
//  ContinueWatchingRow.swift
//  Lume
//
//  The Continue Watching rail on Home, Movies and Series: landscape cards with
//  the title's TMDB backdrop, its logo bottom-left, and under it what's left —
//  time for a movie, the episode and its time for a series — always as text.
//  Progress runs flush along the card's bottom edge (`ArtworkProgressBar`).
//  Finished titles leave the rail (`ContinueWatching`).
//
//  Cards are 1.4× a poster's width (16:9), so the rail shows fewer, larger
//  titles than the poster rails around it, at the same spacing.
//

import SwiftData
import SwiftUI

enum ContinueWatchingMetrics {
    static let cardWidth: CGFloat = (PosterCardMetrics.posterWidth * 1.4).rounded()
    static let cardHeight: CGFloat = (cardWidth * 9 / 16).rounded()
    /// The most the logo may take.
    static let infoWidth: CGFloat = (cardWidth * 0.6).rounded()
    static let logoMaxHeight: CGFloat = (cardHeight * 0.3).rounded()
    static let rowHeight: CGFloat = cardHeight + 2 * PosterCardMetrics.railVerticalPadding
    /// TMDB sizes: the card is never wider than ~340pt (tvOS), so `w780`
    /// covers 2× without pulling a 1920px hero backdrop per card.
    static let backdropSize = "w780"
    static let logoSize = "w500"

    #if os(tvOS)
        static let inset: CGFloat = 16
        /// The foundations' Caption: 22 Medium.
        static let labelFont: Font = .system(size: 22, weight: .medium)
        static let glyphFont: Font = .system(size: 16, weight: .bold)
        static let fallbackTitleFont: Font = .system(size: 26, weight: .bold)
    #else
        static let inset: CGFloat = 8
        static let labelFont: Font = .system(size: 11, weight: .medium)
        static let glyphFont: Font = .system(size: 8, weight: .bold)
        static let fallbackTitleFont: Font = .system(size: 13, weight: .bold)
    #endif
}

struct ContinueWatchingRow: View {
    /// In-progress titles (and, on Home, recently watched channels) — the
    /// caller has already taken finished ones out (`ContinueWatchingLoader`).
    let items: [HomeMediaItem]
    /// Where each series continues, loaded by the screen for both of its
    /// watch rails.
    let series: ContinueWatchingLoader.Result
    let onPlayLive: (LiveStream) -> Void
    /// The full collection behind "Show All" (Movies and Series pages).
    var showAll: LibraryCollection?
    var onRemove: ((HomeMediaItem) -> Void)?
    var onStartMultiView: ((LiveStream) -> Void)?
    /// tvOS: pressing left on the row's first card — see `onLeadingEdgeLeft`.
    var onLeadingLeft: (() -> Void)?
    var animationNamespace: Namespace.ID?

    @Environment(\.modelContext) private var modelContext
    @State private var artwork: [String: ContinueWatchingArtwork] = [:]

    var body: some View {
        let visible = items
        if !visible.isEmpty {
            PosterRail(title: Text("Continue Watching"), showAll: showAll,
                       groupsFocus: true, rowHeight: ContinueWatchingMetrics.rowHeight)
            {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                    ContinueWatchingCell(
                        item: item,
                        continuation: continuation(for: item),
                        artwork: artwork[item.id],
                        onPlayLive: onPlayLive,
                        onRemove: onRemove,
                        onStartMultiView: onStartMultiView,
                        animationNamespace: animationNamespace
                    )
                    .onLeadingEdgeLeft(index == 0 ? onLeadingLeft : nil)
                }
            }
            .task(id: artworkKey) { await fetchMissingArtwork() }
        }
    }

    private func continuation(for item: HomeMediaItem) -> SeriesContinuation? {
        guard case let .series(show) = item else { return nil }
        return series.continuations[show.id]
    }

    // MARK: Artwork

    private var artworkKey: [String] {
        items.compactMap { ContinueWatchingArtworkRequest($0)?.id }
    }

    /// Titles that reached the rail without TMDB artwork get it fetched, a few
    /// at a time, the way the hero does (`SectionFeed+HeroArtwork`). The paths
    /// are kept here too: a model already on screen can stay stale after the
    /// background save.
    private func fetchMissingArtwork() async {
        let requests = items.compactMap(ContinueWatchingArtworkRequest.init)
            .filter { artwork[$0.id] == nil }
            .prefix(6)
        guard !requests.isEmpty else { return }
        let manager = ContentSyncManager(modelContainer: modelContext.container)
        for request in requests {
            guard !Task.isCancelled else { return }
            let details = switch request.kind {
            case .movie: await manager.enrichMovieArtwork(id: request.modelID, tmdbId: request.tmdbId)
            case .series: await manager.enrichSeriesArtwork(id: request.modelID, tmdbId: request.tmdbId)
            }
            if let details {
                artwork[request.id] = ContinueWatchingArtwork(backdropPath: details.backdropPath, logoPath: details.logoPath)
            }
        }
    }
}

/// TMDB artwork fetched this session for a title that had none stored.
struct ContinueWatchingArtwork: Equatable {
    let backdropPath: String?
    let logoPath: String?
}

/// A title in the rail whose TMDB artwork to fetch.
struct ContinueWatchingArtworkRequest {
    enum Kind { case movie, series }
    let id: String
    let modelID: String
    let tmdbId: Int
    let kind: Kind

    /// A movie or series missing its backdrop or logo, that TMDB can be
    /// asked about and hasn't been lately.
    init?(_ item: HomeMediaItem) {
        switch item {
        case let .movie(movie):
            guard let tmdbId = movie.tmdbId,
                  Self.needsArtwork(movie.backdropPath, movie.logoPath, enrichedAt: movie.tmdbArtworkEnrichedAt ?? movie.tmdbEnrichedAt)
            else { return nil }
            self.init(id: item.id, modelID: movie.id, tmdbId: tmdbId, kind: .movie)
        case let .series(show):
            guard let tmdbId = show.tmdbId,
                  Self.needsArtwork(show.backdropPath, show.logoPath, enrichedAt: show.tmdbArtworkEnrichedAt ?? show.tmdbEnrichedAt)
            else { return nil }
            self.init(id: item.id, modelID: show.id, tmdbId: tmdbId, kind: .series)
        case .live:
            return nil
        }
    }

    private init(id: String, modelID: String, tmdbId: Int, kind: Kind) {
        self.id = id
        self.modelID = modelID
        self.tmdbId = tmdbId
        self.kind = kind
    }

    private static func needsArtwork(_ backdrop: String?, _ logo: String?, enrichedAt: Date?) -> Bool {
        guard (backdrop ?? "").isEmpty || (logo ?? "").isEmpty else { return false }
        return !TMDBFreshness.isFresh(enrichedAt)
    }
}

// MARK: - Cell

private struct ContinueWatchingCell: View {
    let item: HomeMediaItem
    let continuation: SeriesContinuation?
    let artwork: ContinueWatchingArtwork?
    let onPlayLive: (LiveStream) -> Void
    var onRemove: ((HomeMediaItem) -> Void)?
    var onStartMultiView: ((LiveStream) -> Void)?
    var animationNamespace: Namespace.ID?

    var body: some View {
        Group {
            switch item {
            case let .movie(movie):
                NavigationLink(value: movie) {
                    ContinueWatchingCard(
                        title: movie.name,
                        backdropURL: backdropURL(movie.backdropPath),
                        posterURL: item.imageURL,
                        logoURL: logoURL(movie.logoPath),
                        fraction: ContinueWatching.fraction(progress: movie.watchProgress, duration: movie.durationSecs) ?? 0,
                        label: ContinueWatching.remaining(progress: movie.watchProgress, duration: movie.durationSecs)
                            .map(ContinueWatching.remainingLabel)
                    )
                    .matchedTransitionSourceIfAvailable(id: movie.id, in: animationNamespace)
                }
                .posterCardButtonStyle()
            case let .series(show):
                NavigationLink(value: show) {
                    ContinueWatchingCard(
                        title: show.name,
                        backdropURL: backdropURL(show.backdropPath),
                        posterURL: item.imageURL,
                        logoURL: logoURL(show.logoPath),
                        fraction: continuation?.fraction ?? 0,
                        label: continuation.map(ContinueWatching.seriesLabel)
                    )
                    .matchedTransitionSourceIfAvailable(id: show.id, in: animationNamespace)
                }
                .posterCardButtonStyle()
            case let .live(stream):
                Button {
                    onPlayLive(stream)
                } label: {
                    ContinueWatchingChannelCard(name: stream.name, logoURL: item.imageURL)
                }
                .posterCardButtonStyle()
            }
        }
        .modifier(HomeItemMenu(
            item: item,
            onRemove: onRemove,
            onVote: nil,
            onStartMultiView: onStartMultiView
        ))
    }

    /// This session's fetched artwork wins: the stored path may be stale.
    private func backdropURL(_ stored: String?) -> URL? {
        TMDBClient.backdropURL(artwork?.backdropPath ?? stored, size: ContinueWatchingMetrics.backdropSize)
    }

    private func logoURL(_ stored: String?) -> URL? {
        TMDBClient.logoURL(artwork?.logoPath ?? stored, size: ContinueWatchingMetrics.logoSize)
    }
}

// MARK: - Cards

private struct ContinueWatchingCard: View {
    let title: String
    let backdropURL: URL?
    /// The portrait provider art, shown filled when there's no backdrop.
    let posterURL: URL?
    let logoURL: URL?
    let fraction: Double
    let label: String?

    private typealias Metrics = ContinueWatchingMetrics

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CachedAsyncImage(url: backdropURL ?? posterURL, maxPixelSize: Metrics.cardWidth) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                default:
                    Rectangle().fill(PosterTitleTile.color(for: title))
                }
            }
            .frame(width: Metrics.cardWidth, height: Metrics.cardHeight)

            // Keeps the logo and the label legible on any backdrop.
            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: UnitPoint(x: 0.5, y: 0.35),
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: Metrics.inset / 2) {
                TitleLogo(
                    url: logoURL,
                    title: title,
                    maxWidth: Metrics.infoWidth,
                    maxHeight: Metrics.logoMaxHeight,
                    alignment: .leading
                ) {
                    Text(title)
                        .font(Metrics.fallbackTitleFont)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: Metrics.infoWidth, alignment: .leading)
                }
                if let label {
                    Text(label)
                        .font(Metrics.labelFont)
                        .foregroundStyle(Color.lumeTextSecondary)
                        // Always over the card's dark scrim, in either appearance.
                        .environment(\.colorScheme, .dark)
                        .lineLimit(1)
                }
            }
            .padding(Metrics.inset)
            .padding(.bottom, fraction > 0 ? ArtworkProgressBar.height : 0)

            if fraction > 0 {
                ArtworkProgressBar(fraction: fraction)
            }
        }
        .frame(width: Metrics.cardWidth, height: Metrics.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: PosterCardMetrics.cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: PosterCardMetrics.cornerRadius))
        #if !os(tvOS)
            .shadow(radius: 2)
        #endif
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label.map { "\(title), \($0)" } ?? title))
    }
}

/// A channel from Recently Watched: its logo on the plate the poster rails use,
/// and LIVE where a title shows its progress.
private struct ContinueWatchingChannelCard: View {
    let name: String
    let logoURL: URL?

    private typealias Metrics = ContinueWatchingMetrics

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color(white: 0.30), Color(white: 0.14)], startPoint: .top, endPoint: .bottom)
            CachedAsyncImage(url: logoURL, maxPixelSize: Metrics.cardWidth) { phase in
                if case let .success(image) = phase {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, Metrics.cardWidth * 0.2)
            .padding(.vertical, Metrics.cardHeight * 0.2)
            .frame(width: Metrics.cardWidth, height: Metrics.cardHeight)

            HStack(spacing: Metrics.inset / 2) {
                Text(name)
                    .font(Metrics.labelFont)
                    .lineLimit(1)
                Text("LIVE")
                    .font(Metrics.glyphFont)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.lumeLiveRed, in: Capsule())
            }
            .foregroundStyle(.white)
            .frame(maxWidth: Metrics.cardWidth - 2 * Metrics.inset, alignment: .leading)
            .padding(Metrics.inset)
        }
        .frame(width: Metrics.cardWidth, height: Metrics.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: PosterCardMetrics.cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: PosterCardMetrics.cornerRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(name))
    }
}
