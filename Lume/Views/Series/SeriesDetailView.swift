//
//  SeriesDetailView.swift
//  Lume
//
//  Apple TV-style series detail screen. Shares the hero / metadata / cast /
//  similar layout with MovieDetailView, adding a season picker and redesigned
//  episode cards. TMDB enrichment and episodes are loaded lazily on appear.
//

import SwiftData
import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif
#if canImport(AppKit)
    import AppKit
#endif

struct SeriesDetailView: View {
    let series: Series
    var animationNamespace: Namespace.ID?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif
    @Query private var playlists: [Playlist]

    @State private var loader: SeriesDetailLoadMachine
    private var isLoadingTMDB: Bool {
        loader.contentID == series.id ? loader.isLoadingTMDB : detailNeedsTMDBFetch(tmdbId: series.tmdbId, enrichedAt: series.tmdbEnrichedAt)
    }

    private var similar: [HomeMediaItem] {
        loader.contentID == series.id ? loader.similar : []
    }

    private var otherSources: [OtherSources.Source] {
        loader.contentID == series.id ? loader.otherSources : []
    }

    @State private var playingMedia: PlayableMedia?
    private var selectedSeason: Int {
        get { loader.selectedSeason }
        nonmutating set { loader.selectedSeason = newValue }
    }

    private var availableSeasons: [Int] {
        loader.contentID == series.id ? loader.availableSeasons : []
    }

    private var episodesBySeason: [Int: [Episode]] {
        loader.contentID == series.id ? loader.episodesBySeason : [:]
    }

    private var isLoadingEpisodes: Bool {
        loader.isLoadingEpisodes
    }

    #if !os(tvOS)
        @State private var downloads = DownloadManager.shared
    #endif

    init(series: Series, animationNamespace: Namespace.ID? = nil) {
        self.series = series
        self.animationNamespace = animationNamespace
        _loader = State(initialValue: SeriesDetailLoadMachine(series: series))
    }

    var body: some View {
        #if os(tvOS)
            TVSeriesDetailView(series: series)
        #else
            Group {
                if isLoadingTMDB {
                    loadingView
                        .transition(.opacity)
                } else {
                    detailView
                        .transition(.opacity)
                }
            }
            .background(backgroundColor)
            #if os(iOS)
                .toolbar(.hidden, for: .tabBar)
                .navigationBarBackButtonHidden(true)
                .toolbarBackground(.hidden, for: .navigationBar)
            #endif
                .toolbar { toolbarContent }
                .task(id: series.id) {
                    await loader.load(series, playlist: seriesPlaylist, in: modelContext)
                }
                .task(id: series.id) {
                    await loader.refreshEpisodesIfStale(series, playlist: seriesPlaylist, in: modelContext)
                }
                .onChange(of: series.episodes.count) { loader.recomputeSeasons(series) }
                .onChange(of: series.similarTMDBIds) { loader.resolveSimilar(series, in: modelContext) }
                .onDisappear { loader.invalidate() }
                .animation(.easeInOut(duration: 0.3), value: isLoadingTMDB)
            #if os(iOS)
                .fullScreenCover(item: $playingMedia) { media in
                    FullScreenPlayerView(media: media)
                }
            #endif
        #endif
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)

            Text(series.name)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("Loading details…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sections

    private func section(title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSectionHeader(title: title)
                .padding(.horizontal, DetailMetrics.contentPadding)
            content()
        }
    }

    private var actions: some View {
        PrimaryPlayButton(
            title: playTitle,
            isEnabled: nextEpisode != nil && seriesPlaylist != nil,
            action: { if let episode = nextEpisode { playEpisode(episode) } }
        )
    }

    private var seasonMenu: some View {
        Menu {
            ForEach(availableSeasons, id: \.self) { season in
                Button {
                    selectedSeason = season
                } label: {
                    if season == selectedSeason {
                        Label("Season \(season)", systemImage: "checkmark")
                    } else {
                        Text("Season \(season)")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("Season \(selectedSeason)")
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var episodesPlaceholder: some View {
        if isLoadingEpisodes {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading episodes…").foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 12) {
                Text("No episodes available").foregroundStyle(.secondary)
                Button("Retry") {
                    Task { await loader.loadEpisodes(series, playlist: seriesPlaylist, in: modelContext) }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var information: some View {
        let rows = informationRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                DetailSectionHeader(title: "Information")
                ForEach(rows, id: \.label) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(row.label))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(row.value)
                            .font(.callout)
                    }
                }
            }
        }
    }

    private var informationRows: [(label: String, value: String)] {
        var rows: [(String, String)] = []
        rows.append(("Title", series.name))
        if let director = series.director, !director.isEmpty {
            rows.append(("Director", director))
        }
        if let genre = series.genre, !genre.isEmpty {
            rows.append(("Genre", genre))
        }
        if let cast = series.cast, !cast.isEmpty, series.orderedCast.isEmpty {
            rows.append(("Cast", cast))
        }
        return rows
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                GlassIconButton(systemImage: "chevron.left", accessibilityLabel: "Back") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                GlassIconButton(
                    systemImage: series.isFavorite ? "heart.fill" : "heart",
                    accessibilityLabel: series.isFavorite ? "Remove from favorites" : "Add to favorites"
                ) { toggleFavorite() }
            }
        #else
            ToolbarItem(placement: .primaryAction) {
                Button {
                    toggleFavorite()
                } label: {
                    Image(systemName: series.isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(series.isFavorite ? .red : .primary)
                        .symbolReplaceTransition(value: series.isFavorite)
                }
                .help(series.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }
        #endif
    }

    // MARK: - Derived data

    private var metadata: DetailMetadata {
        let ratingValue = series.rating.flatMap(Double.init)
        return DetailMetadata(
            genre: series.genre,
            year: DetailFormat.year(from: series.releaseDate),
            duration: nil,
            seasonInfo: availableSeasons.isEmpty ? nil : DetailFormat.seasonCount(availableSeasons.count),
            rating: (ratingValue ?? 0) > 0 ? ratingValue : nil,
            contentRating: series.contentRating
        )
    }

    private var seasonEpisodes: [Episode] {
        episodesBySeason[selectedSeason] ?? []
    }

    /// Play button target — see `SeriesEpisodeProgress.nextEpisode`. Read on
    /// every body evaluation, so it must stay O(episodes) with no sorting.
    private var nextEpisode: Episode? {
        SeriesEpisodeProgress.nextEpisode(in: series.episodes, fallback: seasonEpisodes.first)
    }

    #if !os(tvOS)
        private var backgroundColor: Color {
            #if os(macOS)
                Color(nsColor: .windowBackgroundColor)
            #else
                Color(uiColor: .systemBackground)
            #endif
        }
    #endif

    private var seriesPlaylist: Playlist? {
        playlists.first { series.id.hasPrefix($0.id.uuidString) } ?? playlists.first
    }
}

// MARK: - Content

// Only the iOS / macOS body reaches these: on tvOS `body` hands off to
// `TVSeriesDetailView`, and the episode rows are download-aware.
#if !os(tvOS)
    private extension SeriesDetailView {
        var detailView: some View {
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DetailMetrics.sectionSpacing) {
                        DetailHero(
                            title: series.name,
                            backdropURL: TMDBClient.backdropURL(series.backdropPath),
                            posterFallbackURL: URL(string: series.cover ?? ""),
                            logoURL: TMDBClient.logoURL(series.logoPath),
                            tagline: series.tagline,
                            metadata: metadata,
                            height: DetailMetrics.heroHeight(for: proxy.size),
                            fallbackSymbol: "tv"
                        )

                        actions
                            .padding(.horizontal, DetailMetrics.contentPadding)

                        if let plot = series.plot, !plot.isEmpty {
                            ExpandableText(text: plot)
                                .padding(.horizontal, DetailMetrics.contentPadding)
                        }

                        if !series.externalRatings.isEmpty {
                            ExternalRatingsView(ratings: series.externalRatings)
                                .padding(.horizontal, DetailMetrics.contentPadding)
                        }

                        episodesSection

                        if !series.orderedCast.isEmpty {
                            section(title: "Cast") {
                                CastRow(cast: series.orderedCast)
                            }
                        }

                        if !series.trailers.isEmpty {
                            section(title: "Videos") {
                                VideoRow(videos: series.trailers) { video in
                                    openVideo(video)
                                }
                            }
                        }

                        information
                            .padding(.horizontal, DetailMetrics.contentPadding)

                        if !similar.isEmpty {
                            section(title: "You May Also Like") {
                                SimilarRow(items: similar, animationNamespace: animationNamespace)
                            }
                        }

                        if !otherSources.isEmpty {
                            section(title: "Other Sources") {
                                OtherSourcesRow(sources: otherSources, animationNamespace: animationNamespace)
                            }
                        }
                    }
                    .frame(width: proxy.size.width, alignment: .leading)
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
                .ignoresSafeArea(edges: .top)
            }
        }

        var episodesSection: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    DetailSectionHeader(title: "Episodes")
                    Spacer()
                    if availableSeasons.count > 1 {
                        seasonMenu
                    }
                }
                .padding(.horizontal, DetailMetrics.contentPadding)

                if series.episodes.isEmpty {
                    episodesPlaceholder
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(seasonEpisodes) { episode in
                            DownloadableEpisodeCard(
                                episode: episode,
                                playlist: seriesPlaylist,
                                onPlay: { playEpisode(episode) },
                                onToggleWatched: { toggleWatched(episode) },
                                onMarkPreviousWatched: { markPreviousWatched(episode) },
                                onMarkFollowingUnwatched: { markFollowingUnwatched(episode) }
                            )
                        }
                    }
                    .padding(.horizontal, DetailMetrics.contentPadding)
                }
            }
        }
    }
#endif

// MARK: - Actions

private extension SeriesDetailView {
    func playEpisode(_ episode: Episode) {
        guard let playlist = seriesPlaylist,
              let media = PlayableMedia.from(episode: episode, playlist: playlist) else { return }
        if ExternalPlayback.open(media) { return }
        #if os(macOS)
            MacPlayerWindowRouter.shared.play(media, using: openWindow)
        #else
            playingMedia = media
        #endif
    }

    func toggleFavorite() {
        MediaFavorites.toggle(series, in: modelContext)
    }

    func toggleWatched(_ episode: Episode) {
        episode.setWatched(!episode.isWatched)
        TraktService.shared.syncWatched(episode: episode, watched: episode.isWatched)
        SimklService.shared.syncWatched(episode: episode, watched: episode.isWatched)
        #if !os(tvOS)
            if episode.isWatched {
                downloads.checkAutoDelete(id: episode.id)
            }
        #endif
        try? modelContext.save()
    }

    func markPreviousWatched(_ episode: Episode) {
        episode.markEarlierEpisodesWatched()
        try? modelContext.save()
    }

    func markFollowingUnwatched(_ episode: Episode) {
        episode.markLaterEpisodesUnwatched()
        try? modelContext.save()
    }
}

// MARK: - Derived helpers

private extension SeriesDetailView {
    var playTitle: LocalizedStringKey {
        guard let episode = nextEpisode else { return "Play" }
        let resume = !episode.isWatched && episode.watchProgress > 1
        return resume ? "Resume S\(episode.seasonNum) E\(episode.episodeNum)" : "Play S\(episode.seasonNum) E\(episode.episodeNum)"
    }
}
