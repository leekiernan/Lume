//
//  TVSeriesDetailView.swift
//  Lume
//
//  tvOS series detail screen. Shares the hero / about / ratings / cast / related
//  layout with TVMovieDetailView, adding a focusable season selector and a
//  horizontal rail of large episode cards (the prominent scrolled content, per
//  the Figma template). Episodes and TMDB enrichment load lazily on appear.
//

#if os(tvOS)

    import SwiftData
    import SwiftUI

    struct TVSeriesDetailView: View {
        let series: Series

        @Environment(\.modelContext) private var modelContext
        @Query private var playlists: [Playlist]

        @State private var loader: SeriesDetailLoadMachine
        private var isLoadingTMDB: Bool {
            loader.snapshot(for: series).isLoadingTMDB
        }

        private var similar: [HomeMediaItem] {
            loader.snapshot(for: series).similar
        }

        private var otherSources: [OtherSources.Source] {
            loader.snapshot(for: series).otherSources
        }

        @State private var playingMedia: PlayableMedia?
        private var selectedSeason: Int {
            get { loader.snapshot(for: series).selectedSeason }
            nonmutating set { loader.selectedSeason = newValue }
        }

        private var availableSeasons: [Int] {
            loader.snapshot(for: series).availableSeasons
        }

        private var episodesBySeason: [Int: [Episode]] {
            loader.snapshot(for: series).episodesBySeason
        }

        private var isLoadingEpisodes: Bool {
            loader.snapshot(for: series).isLoadingEpisodes
        }

        @State private var showYouTubeUnavailable = false

        private enum FocusTarget: Hashable {
            case play
            case season(Int)
            case episode(String)
        }

        @FocusState private var focus: FocusTarget?

        init(series: Series) {
            self.series = series
            _loader = State(initialValue: SeriesDetailLoadMachine(series: series))
        }

        var body: some View {
            Group {
                if isLoadingTMDB {
                    TVDetailLoadingView(title: series.name)
                        .transition(.opacity)
                } else {
                    content
                        .transition(.opacity)
                        .onAppear { focus = .play }
                }
            }
            .background(Color.black)
            .ignoresSafeArea()
            .fullScreenCover(item: $playingMedia) { media in
                FullScreenPlayerView(media: media)
            }
            .alert("YouTube Unavailable", isPresented: $showYouTubeUnavailable) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Install the YouTube app on your Apple TV to watch trailers.")
            }
            .task(id: series.id) {
                await loader.load(series, playlist: seriesPlaylist, in: modelContext)
                if !Task.isCancelled { focus = .play }
            }
            .task(id: series.id) {
                await loader.refreshEpisodesIfStale(series, playlist: seriesPlaylist, in: modelContext)
            }
            .onChange(of: series.episodes.count) { loader.recomputeSeasons(series) }
            .onChange(of: series.similarTMDBIds) { loader.resolveSimilar(series, in: modelContext) }
            .onDisappear { loader.invalidate() }
            .animation(.easeInOut(duration: 0.3), value: isLoadingTMDB)
        }

        private var content: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: TVDetailMetrics.sectionSpacing) {
                    hero

                    episodesSection

                    aboutSection

                    if !series.orderedCast.isEmpty {
                        TVRail(title: "Cast", items: series.orderedCast) { member in
                            TVCastCard(member: member)
                        }
                    }

                    if !series.trailers.isEmpty {
                        TVRail(title: "Videos", items: series.trailers) { video in
                            TVVideoCard(video: video) {
                                openVideo(video) { showYouTubeUnavailable = true }
                            }
                        }
                    }

                    if !similar.isEmpty {
                        TVRail(title: "You May Also Like", items: similar) { item in
                            posterLink(for: item)
                                .mediaFavoriteMenu(item, in: modelContext)
                        }
                    }

                    if !otherSources.isEmpty {
                        TVRail(title: "Other Sources", items: otherSources) { source in
                            // No favorite menu: an entry here is the same title on
                            // a *different* playlist, so favoriting it would create a
                            // favorite the playlist-scoped Favorites rail never shows.
                            posterLink(for: source.item, badge: source.playlistName)
                        }
                    }
                }
                .padding(.bottom, 100)
            }
            .scrollClipDisabled()
            .defaultFocus($focus, .play)
        }

        // MARK: - Hero

        private var hero: some View {
            TVDetailHero(
                title: series.name,
                backdropURL: TMDBClient.backdropURL(series.backdropPath),
                posterFallbackURL: URL(string: series.cover ?? ""),
                logoURL: TMDBClient.logoURL(series.logoPath),
                tagline: series.tagline,
                rating: rating5,
                badge: series.contentRating,
                metaItems: heroMetaItems,
                fallbackSymbol: "tv"
            ) {
                TVPlayButton(
                    title: playTitle,
                    isEnabled: nextEpisode != nil && seriesPlaylist != nil,
                    action: { if let episode = nextEpisode { playEpisode(episode) } }
                )
                .focused($focus, equals: .play)

                HStack(spacing: 18) {
                    TVSecondaryActionButton(
                        title: series.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: series.isFavorite ? "heart.fill" : "heart",
                        action: toggleFavorite
                    )
                    Spacer(minLength: 0)
                }
            }
        }

        // MARK: - Episodes

        private var episodesSection: some View {
            VStack(alignment: .leading, spacing: 22) {
                TVSectionHeader(title: "Episodes")
                    .padding(.horizontal, TVDetailMetrics.horizontalInset)

                if availableSeasons.count > 1 {
                    seasonSelector
                }

                if series.episodes.isEmpty {
                    episodesPlaceholder
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: TVDetailMetrics.railSpacing) {
                            ForEach(seasonEpisodes) { episode in
                                TVEpisodeCard(
                                    episode: episode,
                                    onPlay: { playEpisode(episode) },
                                    onToggleWatched: { toggleWatched(episode) },
                                    onMarkPreviousWatched: { markPreviousWatched(episode) },
                                    onMarkFollowingUnwatched: { markFollowingUnwatched(episode) }
                                )
                                .focused($focus, equals: .episode(episode.id))
                            }
                        }
                        .padding(.horizontal, TVDetailMetrics.horizontalInset)
                        .padding(.vertical, 24)
                    }
                    .scrollClipDisabled()
                    // When focus moves INTO the rail (e.g. down from Play), the
                    // enclosing focus section would otherwise pick the card
                    // nearest the SECTION's center — mid-rail, not the first
                    // episode. `.userInitiated` re-applies this default on
                    // user-driven entry, not just on appearance.
                    .defaultFocus(
                        $focus,
                        .episode(seasonEpisodes.first?.id ?? ""),
                        priority: .userInitiated
                    )
                }
            }
            .focusSection()
        }

        private var seasonSelector: some View {
            ScrollView(.horizontal) {
                HStack(spacing: 18) {
                    ForEach(availableSeasons, id: \.self) { season in
                        Button("Season \(season)") {
                            withAnimation(.easeInOut(duration: 0.2)) { selectedSeason = season }
                        }
                        .buttonStyle(TVChipButtonStyle(isSelected: season == selectedSeason))
                        .focused($focus, equals: .season(season))
                    }
                }
                .padding(.horizontal, TVDetailMetrics.horizontalInset)
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()
            .focusSection()
            // Entering the selector lands on the CURRENT season's chip, not
            // whichever chip the focus section's center-pick would choose.
            .defaultFocus($focus, .season(selectedSeason), priority: .userInitiated)
        }

        @ViewBuilder
        private var episodesPlaceholder: some View {
            if isLoadingEpisodes {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading episodes…")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.6))
                }
            } else {
                VStack(spacing: 16) {
                    Text("No episodes available")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.6))
                    Button("Retry") { Task { await loader.loadEpisodes(series, playlist: seriesPlaylist, in: modelContext) } }
                        .buttonStyle(TVChipButtonStyle(isSelected: false))
                }
            }
        }

        // MARK: - About / ratings / information

        private var aboutSection: some View {
            HStack(alignment: .top, spacing: 56) {
                VStack(alignment: .leading, spacing: 22) {
                    TVSectionHeader(title: "About")
                    if let plot = series.plot, !plot.isEmpty {
                        TVAboutText(text: plot)
                    } else {
                        Text("No description available.")
                            .font(.system(size: 26))
                            .foregroundStyle(.white.opacity(0.6))
                    }

                    if !series.externalRatings.isEmpty {
                        TVExternalRatingsView(ratings: series.externalRatings)
                            .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !informationItems.isEmpty {
                    TVInfoCard(title: "Information", items: informationItems)
                        .frame(width: 560)
                }
            }
            .padding(.horizontal, TVDetailMetrics.horizontalInset)
            .focusSection()
        }

        // MARK: - Rail items

        @ViewBuilder
        private func posterLink(for item: HomeMediaItem, badge: String? = nil) -> some View {
            switch item {
            case let .movie(movie):
                NavigationLink(value: movie) {
                    TVPosterCard(item: item, badge: badge)
                }
                .buttonStyle(TVCardButtonStyle())
            case let .series(series):
                NavigationLink(value: series) {
                    TVPosterCard(item: item, badge: badge)
                }
                .buttonStyle(TVCardButtonStyle())
            case .live:
                EmptyView()
            }
        }

        // MARK: - Derived data

        private var rating5: Double {
            if let raw = series.rating5Based, let value = Double(raw), value > 0 { return min(value, 5) }
            if let raw = series.rating, let value = Double(raw), value > 0 { return min(value / 2, 5) }
            return 0
        }

        private var heroMetaItems: [TVMetaItem] {
            var items: [TVMetaItem] = []
            if let date = DetailFormat.date(from: series.releaseDate)
                ?? DetailFormat.year(from: series.releaseDate)
            {
                items.append(TVMetaItem(label: "Released", value: date))
            }
            if let genre = series.genre, !genre.isEmpty {
                items.append(TVMetaItem(label: "Genre", value: shortGenre(genre)))
            }
            if !availableSeasons.isEmpty {
                items.append(TVMetaItem(label: "Seasons", value: DetailFormat.seasonCount(availableSeasons.count)))
            }
            return items
        }

        private var informationItems: [TVMetaItem] {
            var items: [TVMetaItem] = []
            items.append(TVMetaItem(label: "Playlist Title", value: series.name))
            if let director = series.director, !director.isEmpty {
                items.append(TVMetaItem(label: "Creator", value: director))
            }
            if let genre = series.genre, !genre.isEmpty {
                items.append(TVMetaItem(label: "Genre", value: genre))
            }
            if let cast = series.cast, !cast.isEmpty, series.orderedCast.isEmpty {
                items.append(TVMetaItem(label: "Cast", value: cast))
            }
            if let cert = series.contentRating, !cert.isEmpty {
                items.append(TVMetaItem(label: "Rated", value: cert))
            }
            return items
        }

        private func shortGenre(_ genre: String) -> String {
            genre.split(separator: ",").prefix(2)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: ", ")
        }

        private var seasonCountLabel: String {
            availableSeasons.count == 1 ? "1 Season" : "\(availableSeasons.count) Seasons"
        }

        private var seasonEpisodes: [Episode] {
            episodesBySeason[selectedSeason] ?? []
        }

        /// Play button target — see `SeriesEpisodeProgress.nextEpisode`. Read
        /// more than once per body evaluation (play button + `playTitle`), so
        /// it must stay O(episodes) with no sorting.
        private var nextEpisode: Episode? {
            SeriesEpisodeProgress.nextEpisode(in: series.episodes, fallback: seasonEpisodes.first)
        }

        private var playTitle: LocalizedStringKey {
            guard let episode = nextEpisode else { return "Play" }
            if !episode.isWatched, episode.watchProgress > 1 {
                return "Resume S\(episode.seasonNum) E\(episode.episodeNum)"
            }
            return "Play S\(episode.seasonNum) E\(episode.episodeNum)"
        }

        private var seriesPlaylist: Playlist? {
            playlists.first { series.id.hasPrefix($0.id.uuidString) } ?? playlists.first
        }
    }

    // MARK: - Actions & related titles

    private extension TVSeriesDetailView {
        func playEpisode(_ episode: Episode) {
            guard let playlist = seriesPlaylist,
                  let media = PlayableMedia.from(episode: episode, playlist: playlist) else { return }
            if ExternalPlayback.open(media) { return }
            playingMedia = media
        }

        func toggleFavorite() {
            MediaFavorites.toggle(series, in: modelContext)
        }

        func toggleWatched(_ episode: Episode) {
            episode.setWatched(!episode.isWatched)
            TraktService.shared.syncWatched(episode: episode, watched: episode.isWatched)
            SimklService.shared.syncWatched(episode: episode, watched: episode.isWatched)
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

    // MARK: - Season chip style

    /// A focusable selectable pill used by the season selector and small
    /// secondary actions.
    struct TVChipButtonStyle: ButtonStyle {
        var isSelected: Bool

        func makeBody(configuration: Configuration) -> some View {
            StyleBody(configuration: configuration, isSelected: isSelected)
        }

        struct StyleBody: View {
            let configuration: ButtonStyleConfiguration
            let isSelected: Bool
            @Environment(\.isFocused) private var isFocused

            var body: some View {
                let highlighted = isFocused || isSelected
                configuration.label
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(highlighted ? .black : .white)
                    .padding(.horizontal, 28)
                    .frame(height: 60)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(fill)
                    )
                    .scaleEffect(isFocused ? 1.06 : 1.0)
                    .animation(.easeOut(duration: 0.18), value: isFocused)
                    .animation(.easeOut(duration: 0.18), value: isSelected)
            }

            private var fill: AnyShapeStyle {
                if isFocused { return AnyShapeStyle(.white) }
                if isSelected { return AnyShapeStyle(.white.opacity(0.85)) }
                return AnyShapeStyle(.regularMaterial)
            }
        }
    }

    #Preview("TV Series") {
        let container = previewContainer()
        let series = PreviewData.sampleSeries
        series.backdropPath = "/abc123backdrop.jpg"
        series.tagline = "All Hail the King."
        series.contentRating = "TV-MA"
        return NavigationStack {
            TVSeriesDetailView(series: series)
        }
        .modelContainer(container)
    }

#endif
