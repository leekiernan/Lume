//
//  SportsHubView.swift
//  Lume
//
//  The Sports Hub tab. Follow leagues and teams for fixtures, live scores and a
//  one-tap route to the channel carrying a live game. A Lume Pro feature: free
//  users see the locked state, premium users the hub.
//
//  Data comes from `SportsStore` (cached snapshots), the followed set from
//  `SportsFollowService`, and channel resolution from `SportsChannelResolver` —
//  run once per visible fixture set off the main thread, never per card. The
//  page is what's live and coming, a row per follow in the viewer's order
//  (`SportsHubGrouping`); the browse panel narrows it to one follow, and a
//  team's page adds its club season.
//

import SwiftData
import SwiftUI

struct SportsHubView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    @Environment(DeepLinkRouter.self) private var router: DeepLinkRouter?
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif

    @State private var premium = PremiumManager.shared
    @State private var store = SportsStore.shared
    @State private var follows = SportsFollowService.shared
    @State private var epg = EPGSyncService.shared

    @State private var scope: SportsHubScope
    /// Set on a team's own page, pushed from the hub; `nil` on the hub.
    private let pageKey: String?
    /// Follows taken off the hub in Settings ▸ Sports.
    @AppStorage(SportsHubLayout.hiddenKey) private var hiddenFollowsRaw = ""
    @State private var resolution = SportsFixtureResolutionMachine()
    private var resolved: [String: [ResolvedChannel]] {
        resolution.resolved
    }

    @State private var heroSelection = SportsHeroSelectionMachine()
    @State private var highlightsLoad = SportsHighlightsLoadMachine()
    @State private var selectedFixture: SportsFixture?
    @State private var pickerFixture: SportsFixture?
    @State private var showManageTeams = false
    @State private var showingBrowse = false
    @State private var showPaywall = false
    @State private var pendingEvent: SportsPayPerView.Event?
    /// A team page's season: drawn below its games, and the source of the
    /// games it has beyond the followed competition.
    @State private var seasonLoad = SportsTeamSeasonLoadMachine()
    // The library toolbar every area carries: playlist, sort, sync, settings.
    @Query private var playlists: [Playlist]
    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""
    @AppStorage(SortStorageKey.sportsCategories) private var categorySortRaw: String = CategorySortOption.playlist.rawValue
    @AppStorage(SortStorageKey.sportsContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue
    @State private var showingSync = false
    @State private var showingSettings = false
    @State private var localPath = NavigationPath()
    /// The player, and media waiting for a closing sheet. Unused on macOS,
    /// where playback opens a window.
    @State private var playback = SportsPlaybackPresentation()

    init(pageKey: String? = nil) {
        self.pageKey = pageKey
        _scope = State(initialValue: pageKey.map { .follow($0) } ?? .all)
    }

    /// The hub owns the stack its follows' pages push onto, as Movies'
    /// landing page does for its categories; a page is the same screen, fixed
    /// to one follow.
    var body: some View {
        if pageKey == nil {
            NavigationStack(path: pathBinding) {
                screen
                    // The same title and toolbar as Movies, Series and Live TV,
                    // in the same order — item order in the bar follows it.
                    .platformNavigationTitle("Sports")
                    .profileMenuToolbar()
                    .libraryToolbar(config: LibraryToolbarConfiguration(
                        playlists: playlists,
                        selectedPlaylistID: $selectedPlaylistID,
                        categorySortRaw: $categorySortRaw,
                        contentSortRaw: $contentSortRaw,
                        showingSync: $showingSync,
                        showingSettings: $showingSettings,
                        activePlaylist: playlists.active(for: selectedPlaylistID)
                    ))
                    .browseSidebarToolbar(isPresented: $showingBrowse, isEnabled: premium.isPremium)
                    .navigationDestination(for: SportsFollowRoute.self) { route in
                        SportsHubView(pageKey: route.key)
                    }
            }
            // Above the stack, so the panel covers the navigation bar too — the
            // bar draws over anything inside the stack.
            .overlay(alignment: .leading) {
                if premium.isPremium {
                    SportsBrowseSidebar(
                        isPresented: $showingBrowse,
                        entries: grouping.sidebarEntries,
                        onSelect: { key in
                            showingBrowse = false
                            open(follow: key)
                        },
                        onManageTeams: {
                            showingBrowse = false
                            showManageTeams = true
                        }
                    )
                }
            }
        } else {
            screen
        }
    }

    private var screen: some View {
        let fixtures = premium.isPremium ? visibleFixtures : []
        return Group {
            if premium.isPremium {
                hubContent(fixtures)
            } else {
                lockedState
            }
        }
        .sheet(isPresented: $showManageTeams) { ManageTeamsSheet() }
        .sheet(item: $selectedFixture, onDismiss: presentPendingMedia) { fixture in
            GameDetailSheet(fixture: fixture, resolved: resolved[fixture.id] ?? [], onWatch: watch)
        }
        .sheet(item: $pickerFixture, onDismiss: presentPendingMedia) { fixture in
            ChannelPickerSheet(fixture: fixture, resolved: resolved[fixture.id] ?? [], onWatch: watch)
        }
        .paywall(isPresented: $showPaywall, highlight: .sportsHub)
        .payPerViewConfirmation($pendingEvent, onWatch: playEvent)
        #if os(iOS) || os(visionOS)
            .fullScreenCover(item: $playback.playing) { media in
                FullScreenPlayerView(media: media)
            }
        #endif
            .onAppear(perform: onAppear)
            .onDisappear { SportsSyncService.shared.endLivePolling() }
    }

    // MARK: - Content

    private func hubContent(_ fixtures: [SportsFixture]) -> some View {
        Group {
            if follows.follows.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        SportsOnboardingCard { showManageTeams = true }
                        highlightsRail()
                    }
                    .padding()
                }
            } else if pageKey != nil {
                followPage(grouping.pageFixtures(season: grouping.scopedTeam.flatMap { seasonLoad.season(for: $0.id) }))
            } else {
                followedContent(fixtures)
            }
        }
        .task(id: follows.follows.map(\.key)) {
            if pageKey == nil { await loadHighlights() }
        }
    }

    /// Big this week, less the fixtures already offered by the hero carousel.
    @ViewBuilder
    private func highlightsRail(excluding fixtureIDs: Set<String> = []) -> some View {
        let highlights = highlightsLoad.result
        let picks = highlights.highlights.filter { !fixtureIDs.contains($0.fixture.id) }
        if !picks.isEmpty || !highlights.payPerView.isEmpty {
            SportsHighlightsRail(
                highlights: picks,
                payPerView: highlights.payPerView,
                availability: { fixture in
                    SportsChannelAvailability(highlights.resolved[fixture.id], startDate: fixture.headlineDate, preference: .current)
                },
                onOpen: { selectedFixture = $0 },
                onWatchEvent: watchEvent
            )
        }
    }

    private func loadHighlights() async {
        let request = highlightsLoad.begin()
        let followedTeams = Set(follows.follows.filter { $0.kind == .team }.map(\.key))
        let result = await SportsHighlightsPipeline.run(
            container: modelContext.container, restriction: restriction, followedTeamIds: followedTeams,
            overrides: SportsFlagshipOverrides.shared.marks
        )
        // A superseded request's result is ignored by the machine, so one that
        // lands as the view goes away still counts.
        highlightsLoad.finish(request, result: result)
    }

    private var heroAvailableIDs: Set<String> {
        Set(
            (resolved.merging(highlightsLoad.result.resolved) { current, cached in current.isEmpty ? cached : current })
                .filter { !$0.value.isEmpty }
                .map(\.key)
        )
    }

    private func followedContent(_ fixtures: [SportsFixture]) -> some View {
        let candidates = grouping.heroCandidates(
            in: fixtures, highlights: highlightsLoad.result.highlights.map(\.fixture), availableIDs: heroAvailableIDs
        )
        let hero = heroSelection.displayed(in: candidates, context: heroSelectionContext)?.fixture
        let carouselCandidates = Array(heroSelection.carouselCandidates(in: candidates, context: heroSelectionContext).prefix(5))
        let carouselFixtureIDs = Set(carouselCandidates.map(\.id))
        // Movies' structure: the hero opens the scroll view and runs under the
        // bar; the rows follow.
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                heroCarousel(carouselCandidates)
                statusHints
                    .padding(.horizontal)
                SportsSectionsView(
                    // Carousel pages lead on their own, not again below.
                    groups: grouping.groups(for: fixtures.filter { !carouselFixtureIDs.contains($0.id) }),
                    resolved: resolved,
                    isFollowed: isFollowed,
                    onOpenDetail: { selectedFixture = $0 },
                    onWatch: watch,
                    onFollowToggle: toggleFollow,
                    onPickChannel: { pickerFixture = $0 },
                    onSelectFollow: { open(follow: $0) }
                )
                .padding(.horizontal)
                if scope == .all {
                    highlightsRail(excluding: carouselFixtureIDs)
                        .padding(.horizontal)
                }
            }
            // The hero fills the top inset itself when it's showing.
            .padding(.top, carouselCandidates.isEmpty ? PosterCardMetrics.sectionVerticalPadding : 0)
            .padding(.bottom, PosterCardMetrics.sectionVerticalPadding)
        }
        .ignoresSafeArea(edges: carouselCandidates.isEmpty ? [] : .top)
        // A headline from later in the week isn't on screen, but still wants
        // its channel once the guide reaches it.
        .task(id: resolveKey(fixtures + offScreen(hero, in: fixtures))) {
            await runResolve(fixtures + offScreen(hero, in: fixtures))
        }
        .task(id: heroSelectionKey(for: candidates)) {
            heroSelection.reconcile(candidates: candidates, context: heroSelectionContext)
        }
    }

    private func heroAvailability(_ fixture: SportsFixture) -> SportsChannelAvailability {
        SportsChannelAvailability(
            resolved[fixture.id] ?? highlightsLoad.result.resolved[fixture.id],
            startDate: fixture.headlineDate,
            preference: .current
        )
    }

    /// The shared hero carousel Home, Movies and Series use, with a game's
    /// artwork and copy.
    @ViewBuilder
    private func heroCarousel(_ candidates: [SportsHeroSelectionMachine.Candidate]) -> some View {
        if !candidates.isEmpty {
            HeroCarousel(
                items: candidates,
                imageURL: { _ in nil },
                backdrop: { SportsArtworkBackdrop(fixture: $0.fixture, size: .hero) },
                info: { candidate, isCompact in
                    SportsHeroInfo(
                        fixture: candidate.fixture,
                        isCompact: isCompact,
                        availability: heroAvailability(candidate.fixture),
                        onWatch: watch,
                        onOpen: { selectedFixture = candidate.fixture }
                    )
                }
            )
        }
    }

    /// Guide sync, a failed refresh, and how old the scores are.
    @ViewBuilder
    private var statusHints: some View {
        if epg.isSyncing {
            hint("Updating guide…", icon: "arrow.triangle.2.circlepath")
        }
        if store.refreshError {
            hint("Scores unavailable — showing your saved data.", icon: "wifi.slash")
        }
        if let fetchedAt = store.newestSnapshotDate(in: displayLeagueIds) {
            SportsFreshnessLabel(fetchedAt: fetchedAt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var lockedState: some View {
        ContentUnavailableView {
            Label {
                Text(PremiumFeature.sportsHub.title)
            } icon: {
                Image(systemName: "sportscourt")
            }
        } description: {
            Text(PremiumFeature.sportsHub.subtitle)
        } actions: {
            Button("Unlock Sports Hub") { showPaywall = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private func hint(_ text: LocalizedStringKey, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Lifecycle

    private func onAppear() {
        store.loadCached(leagueIds: displayLeagueIds)
        SportsSyncService.shared.refreshIfStale()
        SportsSyncService.shared.beginLivePolling()
    }

    /// Resolves the currently visible fixtures to the viewer's channels in one
    /// off-main pass, re-running when the fixture set changes or an EPG refresh
    /// finishes (fresh sub-titles sharpen matching).
    private func offScreen(_ hero: SportsFixture?, in fixtures: [SportsFixture]) -> [SportsFixture] {
        guard let hero, !fixtures.contains(where: { $0.id == hero.id }) else { return [] }
        return [hero]
    }

    private func resolveKey(_ fixtures: [SportsFixture]) -> String {
        SportsFixtureResolutionMachine.requestKey(for: fixtures, refreshingOn: [epg.isSyncing])
    }

    private var heroSelectionContext: String {
        grouping.heroSelectionContext
    }

    private func heroSelectionKey(for candidates: [SportsHeroSelectionMachine.Candidate]) -> String {
        SportsHeroSelectionMachine.reconcileKey(context: heroSelectionContext, candidates: candidates)
    }

    private func runResolve(_ fixtures: [SportsFixture]) async {
        await SportsFixtureResolution.run(
            $resolution, fixtures: fixtures, container: modelContext.container, restriction: restriction
        )
    }

    // MARK: - Playback

    private func watch(_ channel: ResolvedChannel) {
        guard let media = SportsPlayback.media(for: channel, in: modelContext) else { return }

        let hadSheet = selectedFixture != nil || pickerFixture != nil
        selectedFixture = nil
        pickerFixture = nil
        present(media, afterSheet: hadSheet)
    }

    /// Plays a pay-per-view channel while its event is on; asks first before.
    private func watchEvent(_ event: SportsPayPerView.Event) {
        guard event.isLive(at: Date()) else {
            pendingEvent = event
            return
        }
        playEvent(event)
    }

    private func playEvent(_ event: SportsPayPerView.Event) {
        guard let media = SportsPlayback.media(for: event, in: modelContext) else { return }
        present(media, afterSheet: false)
    }

    /// A sheet's dismissal is not done when its binding drops to `nil`, and a
    /// `fullScreenCover` presented while it is still animating out is torn down
    /// and re-presented by UIKit once the sheet has gone — two player instances,
    /// two stream opens, and the second one trips the provider's connection cap
    /// (LumeEngine fails, KSPlayer gets HTTP 429). So when a sheet was open the
    /// media waits here and the sheet's `onDismiss` presents it.
    private func present(_ media: PlayableMedia, afterSheet: Bool) {
        #if os(macOS)
            MacPlayerWindowRouter.shared.play(media, using: openWindow)
        #elseif os(iOS) || os(visionOS)
            if afterSheet {
                playback.play(media, afterSheet: true)
            } else {
                playback.play(media, afterSheet: false)
            }
        #endif
    }

    private func presentPendingMedia() {
        playback.sheetDidDismiss()
    }

    // MARK: - Follow toggle

    private func toggleFollow(_ team: SportsTeam) {
        follows.toggle(team.id, kind: .team)
    }

    private func isFollowed(_ team: SportsTeam) -> Bool {
        follows.isFollowing(team.id)
    }

    // MARK: - Fixture assembly

    /// The shared selection/grouping rules; the phone hub keeps only its chrome.
    private var grouping: SportsHubGrouping {
        SportsHubGrouping(
            scope: scope, follows: follows.follows, store: store, hiddenKeys: SportsHubLayout.hidden(hiddenFollowsRaw)
        )
    }

    private var displayLeagueIds: [String] {
        grouping.displayLeagueIds
    }

    private var visibleFixtures: [SportsFixture] {
        grouping.visibleFixtures
    }

    private var scopeTitle: String {
        grouping.scopeTitle
    }

    // MARK: - Static helpers

    /// The league id embedded in a team follow key ("espn:soccer/ger.1:132" →
    /// "espn:soccer/ger.1").
    static func leagueId(fromTeamKey key: String) -> String? {
        guard let separator = key.lastIndex(of: ":"), separator > key.startIndex else { return nil }
        return String(key[..<separator])
    }
}

#Preview {
    SportsHubView()
        .modelContainer(for: Playlist.self, inMemory: true)
}

private extension SportsHubView {
    // MARK: - Navigation path

    private var pathBinding: Binding<NavigationPath> {
        if let router {
            return Binding(get: { router.sportsPath }, set: { router.sportsPath = $0 })
        }
        return $localPath
    }

    /// A follow's own page — team or league alike, the hub's screen fixed to it.
    private func open(follow key: String) {
        pathBinding.wrappedValue.append(SportsFollowRoute(key: key))
    }

    /// A team's or league's own page, framed like a Movies category: its
    /// title, then every game it has live or coming in a grid — no hero, no
    /// day switch — and a club's season below.
    func followPage(_ fixtures: [SportsFixture]) -> some View {
        CategoryPage(title: scopeTitle) {
            if fixtures.isEmpty {
                SportsNoGamesView()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                    ForEach(fixtures) { fixture in
                        FixtureCard(
                            fixture: fixture,
                            resolved: resolved[fixture.id] ?? [],
                            isFollowed: isFollowed,
                            showsLeagueMark: grouping.scopedFollow?.kind == .team,
                            onOpenDetail: { selectedFixture = fixture },
                            onWatch: watch,
                            onFollowToggle: toggleFollow,
                            onPickChannel: { pickerFixture = fixture },
                            availability: SportsChannelAvailability(
                                resolved[fixture.id], startDate: fixture.headlineDate, preference: .current
                            )
                        )
                    }
                }
                .padding()
            }
            if let team = grouping.scopedTeam, SportsTeamSeasonLoader.supports(team) {
                SportsTeamSeasonPanel(team: team, season: seasonLoad.season(for: team.id), isLoading: seasonLoad.isLoading(team.id))
                    .padding(.horizontal)
            }
        }
        .task(id: resolveKey(fixtures)) { await runResolve(fixtures) }
        // The team's games across all its competitions, not only the one it
        // was followed from.
        .task(id: grouping.scopedTeam?.id) {
            guard let team = grouping.scopedTeam, SportsTeamSeasonLoader.supports(team) else { return }
            let request = seasonLoad.begin(teamId: team.id)
            let loaded = await SportsTeamSeasonLoader.load(team: team)
            seasonLoad.finish(request, season: loaded)
        }
    }
}
