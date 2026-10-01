//
//  SearchView.swift
//  Lume
//
//  Global search across all content: movies, series, channels and what's on
//  them, within the areas the viewer has switched on. Layout lives in
//  `SearchResultsView`; sections and filters in `SearchResults`.
//

import SwiftData
import SwiftUI

struct SearchView: View {
    @Namespace private var animationNamespace
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif
    @Query private var playlists: [Playlist]

    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""
    @AppStorage(SearchSettings.searchAllPlaylistsKey)
    private var searchAllPlaylists = SearchSettings.searchAllPlaylistsDefault
    /// The active profile's switched-off areas: never searched, offered or named.
    @AppStorage(AppAreaSettings.disabledAreasKey) private var disabledAreasRaw = ""
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var selectedFilter: ContentFilter = .all
    @State private var results = SearchResults()
    /// Now/next for the Now Playing channels, by guide channel id.
    @State private var epgByChannel: [String: ChannelEPG] = [:]
    /// What each result channel's label reads, by stream id.
    @State private var channelLabels: [String: String] = [:]
    @State private var completedSearchKey: SearchKey?
    @State private var playingMedia: PlayableMedia?

    /// Max matches fetched per content type. Keeps the result set bounded so the
    /// list stays responsive even when a playlist holds tens of thousands of items.
    private let resultLimit = 50

    // How long typing has to pause before a query runs. Longer on tvOS: a
    // remote enters a letter every second or so, which a short debounce turns
    // into a full search and list rebuild per letter while the keyboard is
    // still being driven.
    #if os(tvOS)
        private static let debounce: Duration = .milliseconds(700)
    #else
        private static let debounce: Duration = .milliseconds(300)
    #endif

    /// Everything that changes which rows a settled query is allowed to show.
    /// Keeping this separate from the raw input debounce also lets the UI hide
    /// results from the previous provider or viewer immediately.
    private var currentSearchKey: SearchKey {
        SearchKey(
            text: debouncedSearchText,
            filter: selectedFilter,
            allPlaylists: searchAllPlaylists,
            playlistScopeToken: playlistScopeToken,
            visibilityToken: restriction.visibilityToken,
            areas: disabledAreasRaw
        )
    }

    private var searchableAreas: [AppArea] {
        ContentFilter.searchableAreas(disabledRaw: disabledAreasRaw)
    }

    private var filters: [ContentFilter] {
        ContentFilter.available(disabledRaw: disabledAreasRaw)
    }

    private var playlistScopeToken: String {
        if searchAllPlaylists {
            return playlists.map(\.id.uuidString).sorted().joined(separator: "\n")
        }
        return activePlaylist?.id.uuidString ?? ""
    }

    private var isSearchPending: Bool {
        !trimmedQuery.isEmpty
            && (trimmedQuery != debouncedSearchText || completedSearchKey != currentSearchKey)
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .searchField(text: $searchText, prompt: SearchPrompt.field(for: searchableAreas))
                .navigationDestination(for: SearchSection.self) { section in
                    sectionDestination(section)
                }
                .onChange(of: filters) { _, filters in
                    // A filter for an area just switched off falls back to All.
                    if !filters.contains(selectedFilter) { selectedFilter = .all }
                }
                .navigationDestination(for: Movie.self) { movie in
                    MovieDetailView(movie: movie, animationNamespace: animationNamespace)
                    #if os(iOS)
                        .navigationTransition(.zoom(sourceID: movie.id, in: animationNamespace))
                    #endif
                }
                .navigationDestination(for: Series.self) { series in
                    SeriesDetailView(series: series, animationNamespace: animationNamespace)
                    #if os(iOS)
                        .navigationTransition(.zoom(sourceID: series.id, in: animationNamespace))
                    #endif
                }
                .task(id: searchText) {
                    // Debounce raw keystrokes. .task(id:) cancels the in-flight task
                    // (including this sleep) the instant searchText changes, so the
                    // fetch below only fires once typing actually pauses.
                    let trimmed = trimmedQuery
                    guard !trimmed.isEmpty else {
                        debouncedSearchText = ""
                        return
                    }
                    try? await Task.sleep(for: Self.debounce)
                    guard !Task.isCancelled else { return }
                    debouncedSearchText = trimmed
                }
                .task(id: currentSearchKey) {
                    // Re-run whenever the settled query, filter, provider or
                    // viewer visibility changes. Filter and scope changes are
                    // instant; only text input is debounced.
                    await updateResults()
                }
        }
        #if os(iOS) || os(tvOS)
        .fullScreenCover(item: $playingMedia) { media in
            FullScreenPlayerView(media: media)
        }
        #endif
    }

    /// The filter bar is up before the first letter too, so a type can be
    /// chosen before searching. With results it scrolls with them; otherwise
    /// it sits above the centred message.
    @ViewBuilder
    private var content: some View {
        if trimmedQuery.isEmpty {
            withFilterBar {
                ContentUnavailableView(
                    "Search",
                    systemImage: "magnifyingglass",
                    description: Text(SearchPrompt.description(for: searchableAreas))
                )
            }
        } else if isSearchPending {
            // Only once a query has actually run does "No Results" show, so it
            // doesn't flash while the input is debouncing.
            withFilterBar { ProgressView() }
        } else if results.isEmpty {
            withFilterBar { ContentUnavailableView.search }
        } else {
            resultsView(selectedFilter == .all ? .overview : .filtered(selectedFilter)) { filterBar }
        }
    }

    private func withFilterBar(@ViewBuilder _ message: () -> some View) -> some View {
        VStack(spacing: 0) {
            filterBar
            message().frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var filterBar: some View {
        if !filters.isEmpty {
            Picker("Filter", selection: $selectedFilter) {
                ForEach(filters) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func resultsView(
        _ layout: SearchResultsLayout,
        @ViewBuilder header: @escaping () -> some View = { EmptyView() }
    ) -> some View {
        SearchResultsView(
            results: results,
            layout: layout,
            epgByChannel: epgByChannel,
            channelLabels: channelLabels,
            animationNamespace: animationNamespace,
            onPlay: playChannel,
            header: header
        )
    }

    /// A section's "Show All": the same grid every other rail opens, or the
    /// whole channel list.
    @ViewBuilder
    private func sectionDestination(_ section: SearchSection) -> some View {
        switch section {
        case .movies:
            CategoryContentGrid(
                title: String(localized: "Movies"),
                items: results.movies,
                animationNamespace: animationNamespace,
                emptyTitle: "Search", emptyIcon: "magnifyingglass",
                emptyDescription: "Search for movies, series, or live TV channels",
                sortRaw: .constant(""), showsSortMenu: false,
                card: { MovieCardView(movie: $0, fillsWidth: true) }
            )
        case .series:
            CategoryContentGrid(
                title: String(localized: "Series"),
                items: results.series,
                animationNamespace: animationNamespace,
                emptyTitle: "Search", emptyIcon: "magnifyingglass",
                emptyDescription: "Search for movies, series, or live TV channels",
                sortRaw: .constant(""), showsSortMenu: false,
                card: { SeriesCardView(series: $0, fillsWidth: true) }
            )
        case .nowPlaying, .upcoming:
            resultsView(.section(section))
                .navigationTitle(section == .nowPlaying ? "Now Playing" : "Coming Up")
        }
    }

    // MARK: - Playback

    private var activePlaylist: Playlist? {
        playlists.active(for: selectedPlaylistID)
    }

    /// What each channel's label reads: its category and, while searching
    /// across several playlists, its provider — telling two identically named
    /// channels from different providers apart.
    private func labels(for streams: [LiveStream]) -> [String: String] {
        let categories = LiveCategoryNames.names(for: streams, in: modelContext)
        let namesProviders = searchAllPlaylists && playlists.count > 1
        var labels: [String: String] = [:]
        for stream in streams {
            let parts = [
                stream.categoryId.flatMap { categories[$0] },
                namesProviders ? playlists.owner(ofContentID: stream.id)?.name : nil
            ].compactMap(\.self)
            if !parts.isEmpty { labels[stream.id] = parts.joined(separator: " · ") }
        }
        return labels
    }

    private func playChannel(_ stream: LiveStream) {
        // Cross-playlist search surfaces channels the active playlist can't
        // stream: a live URL is built from its playlist's server, credentials
        // and portal, so playing a foreign channel with the active playlist
        // asks the wrong provider for it. Stream ids are per-provider integers,
        // so that doesn't reliably fail — it can quietly play whichever channel
        // holds the same id over there.
        guard let playlist = playlists.owner(ofContentID: stream.id) ?? activePlaylist,
              let media = PlayableMedia.from(stream: stream, playlist: playlist) else { return }
        if ExternalPlayback.open(media) { return }
        #if os(macOS)
            MacPlayerWindowRouter.shared.play(media, using: openWindow)
        #else
            playingMedia = media
        #endif
    }

    // MARK: - Searching

    /// Runs the search. Locally synced content (all Xtream/m3u content and
    /// Stalker live channels) is matched with bounded, predicate-based fetches
    /// on a background context — even a bounded `LIKE '%q%'` scan can't use an
    /// index, so the fetch returns only `Sendable` identifiers that the view
    /// context hydrates by id, and the debounce keeps typing off the main
    /// thread. A Stalker portal's movies/series aren't synced, so they come
    /// from the portal's dedicated search API instead (see `searchStalker`).
    private func updateResults() async {
        let key = currentSearchKey
        let query = debouncedSearchText
        guard !query.isEmpty else {
            results = SearchResults()
            completedSearchKey = key
            return
        }

        let playlist = activePlaylist
        let filter = selectedFilter
        let areas = searchableAreas
        let wantMovies = (filter == .all || filter == .movies) && areas.contains(.movies)
        let wantSeries = (filter == .all || filter == .series) && areas.contains(.series)
        let wantLive = (filter == .all || filter == .liveTV) && areas.contains(.liveTV)

        // A Stalker portal's movies/series aren't synced locally, so they can
        // only be found through the portal's own search API — asked of every
        // Stalker playlist in scope, not just the active one. Live TV (which
        // *is* synced) and every other source type use the local predicate
        // search. Cross-playlist search still runs the local pass too, so other
        // playlists' synced content is included.
        let usePortalForVODSeries = playlist?.sourceType == .stalker && !searchAllPlaylists
        let portal = await portalSearch(query: query, wantMovies: wantMovies, wantSeries: wantSeries)
        guard !Task.isCancelled else { return }

        let localHits = await localSearch(
            query: query, playlist: playlist,
            wantMovies: wantMovies && !usePortalForVODSeries,
            wantSeries: wantSeries && !usePortalForVODSeries,
            wantLive: wantLive
        )
        guard !Task.isCancelled else { return }

        guard currentSearchKey == key else { return }
        let assembled = assembleResults(portal: portal, localHits: localHits)
        let channels = assembled.nowPlaying + assembled.upcoming.map(\.stream)
        channelLabels = labels(for: channels)
        epgByChannel = await nowNext(for: assembled.nowPlaying)
        guard !Task.isCancelled, currentSearchKey == key else { return }
        results = assembled
        completedSearchKey = key
    }

    /// Now/next for the Now Playing channels, resolved off the main thread in
    /// one fetch, as the Live TV list does (`ChannelEPGLoader`).
    private func nowNext(for streams: [LiveStream]) async -> [String: ChannelEPG] {
        let channelIds = Array(Set(streams.compactMap(\.epgChannelId).filter { !$0.isEmpty }))
        guard !channelIds.isEmpty else { return [:] }
        let container = modelContext.container
        return await Task.detached(priority: .userInitiated) {
            ChannelEPGLoader.load(container: container, channelIds: channelIds, now: Date())
        }.value
    }

    /// Portal search hits (element ids) from every Stalker playlist in scope.
    /// A Stalker catalog's movies and series are never synced into the store,
    /// so the portal's own search API is the only way to reach them — which
    /// left a non-active Stalker playlist invisible to search whatever
    /// "Search All Playlists" was set to, since the local pass has nothing of
    /// its VOD to find.
    private func portalSearch(
        query: String, wantMovies: Bool, wantSeries: Bool
    ) async -> (movies: [String], series: [String]) {
        let targets = portalPlaylists
        guard !targets.isEmpty, wantMovies || wantSeries else { return ([], []) }
        let manager = ContentSyncManager(modelContainer: modelContext.container)
        var movies: [[String]] = []
        var series: [[String]] = []
        // One portal at a time: these are separate providers, each with its own
        // connection allowance, and a Stalker middleware is quick to refuse a
        // second session. The debounce means only a settled query gets here,
        // and cancellation stops the walk before the next portal is asked.
        for playlist in targets {
            guard !Task.isCancelled else { break }
            let hits = await manager.searchStalker(
                query: query, playlist: playlist,
                includeMovies: wantMovies, includeSeries: wantSeries, limit: resultLimit
            )
            movies.append(hits.movies)
            series.append(hits.series)
        }
        // Each portal ranks its own hits, so rotate rather than concatenate.
        return (interleaved(movies, limit: resultLimit), interleaved(series, limit: resultLimit))
    }

    /// The Stalker playlists this search asks directly: all of them while
    /// searching across playlists, otherwise the active one if it happens to
    /// be a portal.
    private var portalPlaylists: [Playlist] {
        let candidates = searchAllPlaylists ? playlists : [activePlaylist].compactMap(\.self)
        return candidates.filter { $0.sourceType == .stalker }
    }

    /// Bounded local predicate search, run off the main thread.
    private func localSearch(
        query: String, playlist: Playlist?, wantMovies: Bool, wantSeries: Bool, wantLive: Bool
    ) async -> SearchHits {
        // Scope to the active playlist unless cross-playlist search is on, in
        // which case every playlist is named and each gets its own share of the
        // budget — one catalog would otherwise fill all `resultLimit` rows and
        // the others would look unsearched. Every catalog row's id carries its
        // playlist's UUID as a prefix (see `SearchScope.playlistIDPrefix`), so a
        // prefix test on the indexed `id` limits results to that playlist.
        // Hidden/restricted categories are excluded in the fetch rather than
        // afterwards, so `resultLimit` isn't spent on rows the viewer will
        // never see.
        let scoped = searchAllPlaylists ? playlists : [playlist].compactMap(\.self)
        let request = SearchRequest(
            query: query,
            playlistIDs: scoped.map(\.id.uuidString),
            wantMovies: wantMovies,
            wantSeries: wantSeries,
            wantLive: wantLive,
            excludedCategoryIDs: restriction.excludedCategoryIDs,
            limit: resultLimit
        )
        let container = modelContext.container
        // `Task.detached` starts an unstructured task, which does not inherit
        // this one's cancellation: every keystroke that settled into a query
        // used to leave its scans running to the end, so on a large catalog the
        // superseded work piled up behind the query the viewer is waiting for.
        // Forwarding the cancellation lets `SearchFetcher` bail between its
        // scans; the partial hits it returns are dropped by
        // `updateResults`, which is the task being cancelled.
        let fetch = Task.detached(priority: .userInitiated) {
            SearchFetcher.fetch(container: container, request: request)
        }
        return await withTaskCancellationHandler {
            await fetch.value
        } onCancel: {
            fetch.cancel()
        }
    }

    /// Portal hits first (relevance order), then the local pass. Hydrates rows
    /// in the view context, drops any the active profile restricts, and dedupes
    /// so an already-imported title isn't listed twice. Now Playing is the
    /// channels named for the query, then those airing a matching programme;
    /// Coming Up, matching programmes still to come, soonest first.
    private func assembleResults(
        portal: (movies: [String], series: [String]), localHits: SearchHits
    ) -> SearchResults {
        var seen = Set<String>()
        func shows(_ id: String, categoryID: String?) -> Bool {
            !restriction.hides(categoryID: categoryID) && seen.insert(id).inserted
        }
        var results = SearchResults()
        // The local fetches deliberately run without an ORDER BY so SQLite can
        // stop at the per-type limit instead of sorting every match first (see
        // `SearchFetcher.fetch`). Name order is restored here, over at most
        // `resultLimit` hydrated rows per type, with the comparator
        // `SortDescriptor(\.name)` used.
        let localMovies = sortedByName(hydrateSearchHits(localHits.movies, in: modelContext) as [Movie], name: \.name)
        results.movies = (hydrateMovies(ids: portal.movies) + localMovies)
            .filter { shows("movie-\($0.id)", categoryID: $0.categoryId) }
        let localSeries = sortedByName(hydrateSearchHits(localHits.series, in: modelContext) as [Series], name: \.name)
        results.series = (hydrateSeries(ids: portal.series) + localSeries)
            .filter { shows("series-\($0.id)", categoryID: $0.categoryId) }

        let named = sortedByName(hydrateSearchHits(localHits.streams, in: modelContext) as [LiveStream], name: \.name)
        let programmeStreams = Dictionary(
            (hydrateSearchHits(localHits.programmes.map(\.stream), in: modelContext) as [LiveStream])
                .map { ($0.persistentModelID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let airing = localHits.programmes.filter(\.isCurrent).compactMap { programmeStreams[$0.stream] }
        results.nowPlaying = (named + airing).filter { shows("live-\($0.id)", categoryID: $0.categoryId) }
        results.upcoming = Array(localHits.programmes.filter { !$0.isCurrent }.compactMap { hit in
            programmeStreams[hit.stream].map { UpcomingProgramme(stream: $0, slot: hit.slot) }
        }
        .filter { !restriction.hides(categoryID: $0.stream.categoryId) }
        .prefix(resultLimit))
        return results
    }

    /// Name order, by the comparator `SortDescriptor(\.name)` defaults to.
    private func sortedByName<Model>(_ models: [Model], name: KeyPath<Model, String>) -> [Model] {
        models.sorted { $0[keyPath: name].localizedStandardCompare($1[keyPath: name]) == .orderedAscending }
    }

    /// Fetches `Movie` rows for the given ids in one query, returned in id order.
    private func hydrateMovies(ids: [String]) -> [Movie] {
        guard !ids.isEmpty else { return [] }
        let fetched = (try? modelContext.fetch(
            FetchDescriptor<Movie>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        let byId = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byId[$0] }
    }

    /// Fetches `Series` rows for the given ids in one query, returned in id order.
    private func hydrateSeries(ids: [String]) -> [Series] {
        guard !ids.isEmpty else { return [] }
        let fetched = (try? modelContext.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        let byId = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byId[$0] }
    }
}

// MARK: - Search field

private extension View {
    /// The search field, pinned at the top wherever it lands in the
    /// navigation bar — iPad, the More list, and some iPhones — where it would
    /// otherwise stay hidden until the list is pulled down (iPadOS 26 even
    /// parks it as a collapsed magnifier button). Where the search tab puts
    /// the field in the tab bar instead, that placement still wins.
    func searchField(text: Binding<String>, prompt: String) -> some View {
        modifier(SearchFieldModifier(text: text, prompt: prompt))
    }
}

private struct SearchFieldModifier: ViewModifier {
    @Binding var text: String
    /// Names only the areas that are switched on (`SearchPrompt.field`).
    let prompt: String
    #if os(tvOS)
        @State private var fieldText = FieldText()
    #endif

    func body(content: Content) -> some View {
        #if os(tvOS)
            content.searchable(text: fieldBinding, prompt: Text(prompt))
        #else
            content.searchable(text: $text, placement: placement, prompt: Text(prompt))
        #endif
    }

    #if os(tvOS)
        /// Text typed on the iPhone Remote keyboard appears in the field and is
        /// then deleted again, from the second letter on — the known tvOS
        /// `.searchable` fight between the remote session and SwiftUI writing
        /// its binding back into the field. The getter here answers with the
        /// text the field itself last reported, read from a plain reference
        /// rather than view state, so a write-back can never carry an older
        /// value than the one on screen.
        private var fieldBinding: Binding<String> {
            let fieldText = fieldText
            return Binding(
                get: { fieldText.value },
                set: { newValue in
                    fieldText.value = newValue
                    text = newValue
                }
            )
        }
    #endif

    private var placement: SearchFieldPlacement {
        #if os(iOS)
            .navigationBarDrawer(displayMode: .always)
        #else
            .automatic
        #endif
    }
}

#if os(tvOS)
    /// The search field's latest text. A class, and deliberately not
    /// observable: writing it must not schedule a view update of its own.
    private final class FieldText {
        var value = ""
    }
#endif

// MARK: - Search Key

/// Identity for the fetch task: re-run whenever the query or its permitted
/// provider/content scope changes.
struct SearchKey: Equatable {
    let text: String
    let filter: ContentFilter
    let allPlaylists: Bool
    let playlistScopeToken: String
    let visibilityToken: String
    /// The switched-off areas: turning one on or off changes what is searched.
    var areas = ""
}

// MARK: - Search Settings

enum SearchSettings {
    /// When enabled, search spans every configured playlist. Off by default, so
    /// results stay scoped to the active playlist unless the user opts in.
    static let searchAllPlaylistsKey = "search.allPlaylists"
    static let searchAllPlaylistsDefault = false
}
