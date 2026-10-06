//
//  TVSportsHubScreen.swift
//  Lume
//
//  The tvOS Sports Hub: a purpose-built 10-foot screen. Home's immersive hero
//  carousel with the page title over it — the scope, which opens the browse
//  panel — then full-width horizontal rails of `TVFixtureCard`s: Live Now and
//  a row per follow in the viewer's order (`SportsHubGrouping`), one focus
//  section per row. A team's row ends with its club season; narrowed to the
//  team, the page carries that season below its games. The header scrolls with the page — a pinned bar over an unclipped
//  scroll view had the cards sliding underneath it. It shares the hub's data
//  plumbing — `SportsStore` snapshots, `SportsFollowService` follows, off-main
//  `SportsChannelResolver` — and reuses `SportsHubView`'s static date/assembly
//  helpers so the two hubs stay in step.
//

#if os(tvOS)

    import SwiftData
    import SwiftUI

    /// Focus targets on the hub: the default landing, and where the browse
    /// panel hands focus back to.
    enum TVSportsFocus: Hashable {
        case heroWatch
        case heroDetail
        case card(String)
    }

    struct TVSportsHubScreen: View {
        @Environment(\.modelContext) var modelContext
        @Environment(\.contentRestriction) var restriction
        @Environment(DeepLinkRouter.self) var router: DeepLinkRouter?

        @State private var premium = PremiumManager.shared
        @State private var store = SportsStore.shared
        @State var follows = SportsFollowService.shared
        @State private var epg = EPGSyncService.shared

        @State var scope: SportsHubScope
        /// Set on a follow's own page, pushed from the hub; `nil` on the hub.
        let pageKey: String?
        @State var localPath = NavigationPath()
        /// Follows taken off the hub in Settings ▸ Sports.
        @AppStorage(SportsHubLayout.hiddenKey) private var hiddenFollowsRaw = ""
        /// The scope panel, and where focus was when it opened.
        @State var showingBrowse = false
        @State var browseReturnFocus: TVSportsFocus?
        @State var resolution = SportsFixtureResolutionMachine()
        /// Rebuilt when either machine or the visibility changes — see
        /// `keepingSportsHubChannels`.
        @State var hubChannels = SportsHubChannels.empty

        var resolved: [String: [ResolvedChannel]] {
            hubChannels.resolved
        }

        @State private var heroSelection = SportsHeroSelectionMachine()
        @State var showManageTeams = false
        @State var showPaywall = false
        @State var pendingEvent: SportsPayPerView.Event?
        /// Direct hero/PPV playback. Pushed Match Centre owns its own player.
        @State private var playback = SportsPlaybackPresentation()
        @AppStorage(SportsSyncService.hideScoresKey) private var hidesScores = false
        /// The headlined game from its first minute, when Hide Scores is on and
        /// the channel can replay it — worked out once per game, not per render.
        @State private var heroFromStart: PlayableMedia?
        /// A team page's season: drawn below its games, and the source of the
        /// games it has beyond the followed competition.
        @State var seasonLoad = SportsTeamSeasonLoadMachine()
        /// "Big this week", and the channels its near-term games resolved to.
        @State var highlightsLoad = SportsHighlightsLoadMachine()
        var highlightsResult: SportsHighlightsLoadMachine.Result {
            highlightsLoad.result(for: restriction.visibilityToken)
        }

        /// The headline carousel, and where the page sits against its fold.
        @State private var heroModel = TVSportsHeroModel()
        @State private var heroZone: TVHomeZone = .expanded
        @State private var containerHeight: CGFloat = 0

        @FocusState var focus: TVSportsFocus?

        init(pageKey: String? = nil) {
            self.pageKey = pageKey
            _scope = State(initialValue: pageKey.map { .follow($0) } ?? .all)
        }

        /// The hub owns the stack its follows' pages push onto, as Movies'
        /// landing page does for its categories.
        var body: some View {
            if pageKey == nil {
                NavigationStack(path: pathBinding) {
                    screen
                        .navigationDestination(for: SportsFollowRoute.self) { route in
                            TVSportsHubScreen(pageKey: route.key)
                        }
                        .detailDestinations(path: pathBinding)
                }
            } else {
                screen
            }
        }

        private var screen: some View {
            Group {
                if premium.isPremium {
                    hub
                } else {
                    lockedState
                }
            }
            .keepingSportsHubChannels(
                $hubChannels, resolution: resolution, highlights: highlightsLoad, visibilityToken: restriction.visibilityToken
            )
            .sheet(isPresented: $showManageTeams) { TVManageTeamsPane() }
            .fullScreenCover(item: $playback.playing) { media in
                FullScreenPlayerView(media: media)
            }
            .paywall(isPresented: $showPaywall, highlight: .sportsHub)
            .payPerViewConfirmation($pendingEvent, onWatch: playEvent)
            .onAppear(perform: onAppear)
            .onDisappear { SportsSyncService.shared.endLivePolling() }
        }

        // MARK: - Hub

        private var hub: some View {
            Group {
                if follows.follows.isEmpty {
                    if let first = highlightsResult.highlights.first {
                        highlightsHub(first)
                    } else {
                        onboardingState
                    }
                } else if pageKey != nil {
                    followPage
                } else {
                    content
                        .overlay(alignment: .leading) { browseSidebar }
                }
            }
            .task(id: [restriction.visibilityToken] + follows.follows.map(\.key)) {
                if pageKey == nil { await loadHighlights() }
            }
        }

        /// Home's immersive layout: the slide's artwork fixed full-screen
        /// behind one scrolling page, which opens with the showcase — header at
        /// its top, the headline carousel at its foot — then the rails.
        private var content: some View {
            // One grouping pass per render: the fixtures and groups feed the
            // rails, the default focus and the resolve key alike.
            let fixtures = grouping.visibleFixtures
            let preference = SportsChannelPreference.Context.current
            let availableIDs = hubChannels.availableIDs
            let candidates = grouping.heroCandidates(
                in: fixtures, highlights: highlightsResult.highlights.map(\.fixture), availableIDs: availableIDs
            )
            let plan = SportsHubPresentationPlan(
                fixtures: fixtures,
                candidates: heroSelection.carouselCandidates(in: candidates, context: heroSelectionContext),
                surface: .television,
                highlights: scope == .all ? highlightsResult.highlights.map(\.fixture) : []
            )
            let carousel = plan.carousel
            let carouselIDs = plan.carouselIDs
            let hero = heroModel.displayedHero?.fixture
            // Big this week leaves out whatever the carousel already shows.
            let highlights = highlightsResult.highlights.filter { !carouselIDs.contains($0.fixture.id) }
            // The carousel's games lead the page on their own, not again in a rail.
            let groups = grouping.groups(for: plan.rowFixtures)
            let heroAvailability = hero.map { availability(of: $0, preference: preference) }
            // The displayed slides and highlights refresh with the rows.
            let toResolve = plan.resolutionFixtures
            return ZStack {
                TVSportsHeroBackdrop(fixture: hero, belowFold: heroZone != .expanded)
                    .animation(.easeInOut(duration: 0.8), value: hero?.id)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 36) {
                        if carousel.isEmpty {
                            header.padding(.top, TVSportsMetrics.contentTop)
                        } else {
                            TVSportsHeroShowcase(
                                model: heroModel,
                                availability: { availability(of: $0, preference: preference) },
                                showsScore: { $0.showsScore(hidingScores: hidesScores, reveal: SportsScoreReveal.shared) },
                                focus: $focus,
                                onWatch: watch,
                                onWatchFromStart: heroFromStart.map { media in { playback.play(media, afterSheet: false) } },
                                onOpen: openMatchCentre,
                                header: { header.padding(.top, TVSportsMetrics.contentTop) }
                            )
                        }
                        if plan.showsNoGames(groupsAreEmpty: groups.isEmpty) {
                            noGamesState
                        } else {
                            ForEach(groups) { group in
                                section(for: group, preference: preference)
                            }
                        }
                        if scope == .all, !highlights.isEmpty || !highlightsResult.payPerView.isEmpty {
                            TVSportsHighlightsSection(
                                highlights: highlights,
                                payPerView: highlightsResult.payPerView,
                                availability: highlightAvailability,
                                onSelect: openMatchCentre,
                                onWatchEvent: watchEvent,
                                onLeadingLeft: browseOpener(leading: true)
                            )
                            .padding(.top, 24)
                        }
                    }
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .scrollTargetBehavior(TVHomeFoldBehavior(zone: heroZone, showcaseHeight: carousel.isEmpty ? 0 : showcaseHeight))
                .onScrollGeometryChange(for: TVHomeZone.self) { geometry in
                    TVHomeZone(
                        offset: geometry.contentOffset.y + geometry.contentInsets.top,
                        showcaseHeight: carousel.isEmpty ? 0 : showcaseHeight
                    )
                } action: { _, newZone in
                    guard newZone != heroZone else { return }
                    withAnimation(.easeInOut(duration: 0.5)) { heroZone = newZone }
                }
            }
            // Full-bleed vertically, like Home: the backdrop and the
            // showcase span the real screen; rows keep their side inset.
            .ignoresSafeArea(edges: .vertical)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { containerHeight = $0 }
            .onChange(of: heroZone) { _, zone in heroModel.isPaused = zone != .expanded }
            .onChange(of: carousel.map(\.id), initial: true) { _, _ in heroModel.configure(items: carousel) }
            .task(id: resolveKey(toResolve)) { await runResolve(toResolve) }
            .task(id: heroSelectionKey(for: candidates)) {
                heroSelection.reconcile(candidates: candidates, context: heroSelectionContext)
            }
            .task(id: "\(hero?.id ?? "")|\(hidesScores)|\(heroAvailability?.isAvailable ?? false)") {
                heroFromStart = hero.flatMap { hero in heroAvailability.flatMap { fromStartMedia(hero, availability: $0) } }
            }
        }

        private var showcaseHeight: CGFloat {
            max(containerHeight - TVHomeMetrics.rowPeek, 0)
        }

        private func availability(of fixture: SportsFixture, preference: SportsChannelPreference.Context) -> SportsChannelAvailability {
            SportsChannelAvailability(
                resolved[fixture.id], startDate: fixture.headlineDate, preference: preference
            )
        }

        // MARK: - Header

        /// Status hints over the hero. No title: like Home, the tab names the
        /// page, and the browse panel opens with a left press from the leading
        /// edge of the hero or any row.
        private var header: some View {
            VStack(alignment: .leading, spacing: 10) {
                if epg.isSyncing {
                    hintRow("Updating guide…", icon: "arrow.triangle.2.circlepath")
                }
                if store.refreshError {
                    hintRow("Scores unavailable — showing your saved data.", icon: "wifi.slash")
                }
                if let fetchedAt = store.newestSnapshotDate(in: displayLeagueIds) {
                    SportsFreshnessLabel(fetchedAt: fetchedAt)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(.horizontal, TVSportsMetrics.railInset)
        }

        // MARK: - Sections

        /// The heading matches `HomeRow`'s — subheadline, bold, secondary — so
        /// the hub's rails read like every other rail on the tvOS Home.
        private func section(
            for group: SportsFixtureGroup,
            preference: SportsChannelPreference.Context
        ) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                rowHeader(for: group)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: TVSportsMetrics.railSpacing) {
                        ForEach(group.fixtures) { fixture in
                            TVFixtureCard(
                                fixture: fixture,
                                availability: SportsChannelAvailability(
                                    resolved[fixture.id], startDate: fixture.headlineDate, preference: preference
                                ),
                                showsLeagueName: !group.isSingleLeague
                            ) {
                                openMatchCentre(fixture)
                            }
                            .focused($focus, equals: .card(fixture.id))
                            .onLeadingEdgeLeft(browseOpener(leading: fixture.id == group.fixtures.first?.id))
                        }
                        // A followed club's row ends at its season: the page
                        // narrowed to the team, its table and players below.
                        if let team = seasonTeam(forFollow: group.followKey) {
                            Button {
                                open(follow: team.id)
                            } label: {
                                TVClubSeasonCard(team: team)
                            }
                            .buttonStyle(TVCardButtonStyle(focusScale: 1.05))
                        }
                    }
                    .padding(.horizontal, TVSportsMetrics.railInset)
                    .padding(.vertical, 8)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }

        /// A row's crest and name, styled like `HomeRow`'s heading.
        private func rowHeader(for group: SportsFixtureGroup) -> some View {
            SportsSectionHeading(title: Text(verbatim: group.title), logoURL: group.logoURL, style: .rail)
                .padding(.horizontal, TVSportsMetrics.railInset)
        }

        private func hintRow(_ text: LocalizedStringKey, icon: String) -> some View {
            Label(text, systemImage: icon)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.55))
        }

        // MARK: - Playback

        func watch(_ channel: ResolvedChannel) {
            guard let media = SportsPlayback.media(for: channel, in: modelContext) else { return }

            playback.play(media, afterSheet: false)
        }

        /// A pay-per-view or event channel, straight from its card.
        /// Plays a pay-per-view channel while its event is on; asks first before.
        func watchEvent(_ event: SportsPayPerView.Event) {
            guard event.isLive(at: Date()) else {
                pendingEvent = event
                return
            }
            playEvent(event)
        }

        func playEvent(_ event: SportsPayPerView.Event) {
            guard let media = SportsPlayback.media(for: event, in: modelContext) else { return }
            playback.play(media, afterSheet: false)
        }

        /// Catch-up from kickoff for a live game under Hide Scores.
        private func fromStartMedia(_ fixture: SportsFixture, availability: SportsChannelAvailability) -> PlayableMedia? {
            guard hidesScores, fixture.isInProgress, case let .available(_, best) = availability else { return nil }
            return SportsPlayback.fromStartMedia(for: best, fixture: fixture, in: modelContext)
        }
    }

    /// Both the followed hub and the no-follows highlights page use this one
    /// resolution owner; neither starts a competing request on the other's page.
    extension TVSportsHubScreen {
        func resolveKey(_ fixtures: [SportsFixture]) -> String {
            SportsFixtureResolutionMachine.requestKey(for: fixtures, visibilityToken: restriction.visibilityToken, refreshingOn: [epg.isSyncing])
        }

        func runResolve(_ fixtures: [SportsFixture]) async {
            await SportsFixtureResolution.run(
                $resolution, fixtures: fixtures, container: modelContext.container, restriction: restriction
            )
        }
    }

    private extension TVSportsHubScreen {
        // MARK: - Lifecycle

        func onAppear() {
            store.loadCached(leagueIds: displayLeagueIds)
            SportsSyncService.shared.refreshIfStale()
            SportsSyncService.shared.beginLivePolling()
        }

        var heroSelectionContext: String {
            grouping.heroSelectionContext
        }

        func heroSelectionKey(for candidates: [SportsHeroSelectionMachine.Candidate]) -> String {
            SportsHeroSelectionMachine.reconcileKey(context: heroSelectionContext, candidates: candidates)
        }

        // MARK: - Follow

        private func isFollowed(_ team: SportsTeam) -> Bool {
            follows.isFollowing(team.id)
        }

        // MARK: - Fixture assembly

        /// The shared selection/grouping rules; the tvOS hub keeps only its chrome.
        private var grouping: SportsHubGrouping {
            SportsHubGrouping(
                scope: scope, follows: follows.follows, store: store, hiddenKeys: SportsHubLayout.hidden(hiddenFollowsRaw)
            )
        }

        private var displayLeagueIds: [String] {
            grouping.displayLeagueIds
        }

        private var scopeTitle: String {
            grouping.scopeTitle
        }

        // MARK: - A follow's page

        /// A team's or league's own page, framed like a Movies category: the
        /// heading, every game it has live or coming in a grid — no hero, no
        /// title button, no rows — and a club's season below. Menu goes back.
        var followPage: some View {
            let season = seasonTeam.flatMap { seasonLoad.season(for: $0.id) }
            let fixtures = grouping.pageFixtures(season: season)
            let preference = SportsChannelPreference.Context.current
            return ScrollViewReader { proxy in
                CategoryPage(title: scopeTitle) {
                    Color.clear.frame(height: 0).id(Self.pageTop)
                    if fixtures.isEmpty {
                        // A line, not a screenful: the season sits just below.
                        SportsNoGamesView(presentation: .category)
                    } else {
                        // Four across: the width the hub's rows show, where Movies'
                        // narrower posters fit six.
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: PosterCardMetrics.gridSpacing), count: 4),
                            alignment: .leading,
                            spacing: PosterCardMetrics.gridSpacing
                        ) {
                            ForEach(fixtures) { fixture in
                                TVFixtureCard(
                                    fixture: fixture,
                                    availability: SportsChannelAvailability(
                                        resolved[fixture.id], startDate: fixture.headlineDate, preference: preference
                                    ),
                                    showsLeagueName: grouping.scopedFollow?.kind == .team,
                                    fillsWidth: true
                                ) {
                                    openMatchCentre(fixture)
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 24)
                    }
                    if let team = seasonTeam {
                        TVTeamSeasonSection(
                            team: team,
                            season: season,
                            isLoading: seasonLoad.isLoading(team.id),
                            // With games above, up reaches them; without, the
                            // season's first row is the page's top.
                            onMoveUpFromTop: fixtures.isEmpty
                                ? { withAnimation { proxy.scrollTo(Self.pageTop, anchor: .top) } }
                                : nil
                        )
                        .padding(.top, 24)
                        .padding(.bottom, 60)
                    }
                }
            }
            .task(id: resolveKey(fixtures)) { await runResolve(fixtures) }
            // The team's games across all its competitions, not only the one
            // it was followed from.
            .task(id: seasonTeam?.id) {
                guard let team = seasonTeam else { return }
                let request = seasonLoad.begin(teamId: team.id)
                let loaded = await SportsTeamSeasonLoader.load(team: team)
                seasonLoad.finish(request, season: loaded)
            }
        }

        static let pageTop = "followPage.top"

        /// The team the page is narrowed to, when its season can be shown.
        var seasonTeam: SportsTeam? {
            grouping.scopedTeam.flatMap { SportsTeamSeasonLoader.supports($0) ? $0 : nil }
        }

        /// A followed team's season, when it can be shown — what a team row's
        /// closing card opens.
        func seasonTeam(forFollow key: String?) -> SportsTeam? {
            guard let key, let team = store.team(by: key), follows.follows.contains(where: { $0.key == key && $0.kind == .team }),
                  SportsTeamSeasonLoader.supports(team)
            else { return nil }
            return team
        }
    }

#endif
