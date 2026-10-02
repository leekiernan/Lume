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
        @State var resolved: [String: [ResolvedChannel]] = [:]
        @State private var heroSelection = SportsHeroSelectionMachine()
        @State var selectedFixture: SportsFixture?
        @State var showManageTeams = false
        @State var showPaywall = false
        @State var pendingEvent: SportsPayPerView.Event?
        @State private var playingMedia: PlayableMedia?
        /// Playback queued behind the dismissing detail cover; see `watch`.
        @State private var pendingMedia: PlayableMedia?
        @AppStorage(SportsSyncService.hideScoresKey) private var hidesScores = false
        /// The headlined game from its first minute, when Hide Scores is on and
        /// the channel can replay it — worked out once per game, not per render.
        @State private var heroFromStart: PlayableMedia?
        /// A team page's season, for its games beyond the followed competition.
        @State var pageSeason: SportsTeamSeason?
        /// "Big this week", and the channels its near-term games resolved to.
        @State var highlightsLoad = SportsHighlightsLoadMachine()

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
            .sheet(isPresented: $showManageTeams) { TVManageTeamsPane() }
            .fullScreenCover(item: $selectedFixture, onDismiss: presentPendingMedia) { fixture in
                TVGameDetailSheet(fixture: fixture, resolved: resolved[fixture.id] ?? [], onWatch: watch)
            }
            .fullScreenCover(item: $playingMedia) { media in
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
                    if let first = highlightsLoad.result.highlights.first {
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
            .task(id: follows.follows.map(\.key)) {
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
            let availableIDs = Set(
                (resolved.merging(highlightsLoad.result.resolved) { current, cached in current.isEmpty ? cached : current })
                    .filter { !$0.value.isEmpty }
                    .map(\.key)
            )
            let candidates = grouping.heroCandidates(
                in: fixtures, highlights: highlightsLoad.result.highlights.map(\.fixture), availableIDs: availableIDs
            )
            let carousel = Array(heroSelection.carouselCandidates(in: candidates, context: heroSelectionContext).prefix(Self.carouselLimit))
            let carouselIDs = Set(carousel.map(\.id))
            let hero = heroModel.displayedHero?.fixture
            // Big this week leaves out whatever the carousel already shows.
            let highlights = highlightsLoad.result.highlights.filter { !carouselIDs.contains($0.fixture.id) }
            // The carousel's games lead the page on their own, not again in a rail.
            let groups = grouping.groups(for: fixtures.filter { !carouselIDs.contains($0.id) })
            let heroAvailability = hero.map { availability(of: $0, preference: preference) }
            // Slides from later in the week aren't on screen, but still want
            // their channels once the guide reaches them.
            let toResolve = fixtures + carousel.map(\.fixture).filter { slide in !fixtures.contains { $0.id == slide.id } }
            return ScrollViewReader { _ in
                ZStack {
                    TVSportsHeroBackdrop(fixture: hero, belowFold: heroZone != .expanded)
                        .animation(.easeInOut(duration: 0.8), value: hero?.id)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 36) {
                            if carousel.isEmpty {
                                header.padding(.top, Self.headerTop)
                            } else {
                                TVSportsHeroShowcase(
                                    model: heroModel,
                                    availability: { availability(of: $0, preference: preference) },
                                    showsScore: { $0.showsScore(hidingScores: hidesScores, reveal: SportsScoreReveal.shared) },
                                    focus: $focus,
                                    onWatch: watch,
                                    onWatchFromStart: heroFromStart.map { media in { playingMedia = media } },
                                    onOpen: { selectedFixture = $0 },
                                    header: { header.padding(.top, Self.headerTop) }
                                )
                            }
                            if groups.isEmpty, carousel.isEmpty {
                                noGamesState
                            } else {
                                ForEach(groups) { group in
                                    section(for: group, preference: preference)
                                }
                            }
                            if scope == .all, !highlights.isEmpty || !highlightsLoad.result.payPerView.isEmpty {
                                TVSportsHighlightsSection(
                                    highlights: highlights,
                                    payPerView: highlightsLoad.result.payPerView,
                                    availability: highlightAvailability,
                                    onSelect: { selectedFixture = $0 },
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
                    .defaultFocus($focus, defaultFocus(hero: hero, availability: heroAvailability, groups: groups))
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
        }

        private static let carouselLimit = 8
        /// Clear of the tab bar above, which the full-bleed page now sits under.
        private static let headerTop: CGFloat = 110

        private var showcaseHeight: CGFloat {
            max(containerHeight - TVHomeMetrics.rowPeek, 0)
        }

        private func availability(of fixture: SportsFixture, preference: SportsChannelPreference.Context) -> SportsChannelAvailability {
            SportsChannelAvailability(
                resolved[fixture.id] ?? highlightsLoad.result.resolved[fixture.id], startDate: fixture.headlineDate, preference: preference
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
            .padding(.horizontal, 60)
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
                    LazyHStack(spacing: 24) {
                        ForEach(group.fixtures) { fixture in
                            TVFixtureCard(
                                fixture: fixture,
                                availability: SportsChannelAvailability(
                                    resolved[fixture.id], startDate: fixture.headlineDate, preference: preference
                                ),
                                showsLeagueName: !group.isSingleLeague
                            ) {
                                selectedFixture = fixture
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
                    .padding(.horizontal, 60)
                    .padding(.vertical, 8)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }

        /// A row's crest and name, styled like `HomeRow`'s heading.
        private func rowHeader(for group: SportsFixtureGroup) -> some View {
            HStack(spacing: 10) {
                if let logoURL = group.logoURL {
                    CachedAsyncImage(url: logoURL, maxPixelSize: 40) { phase in
                        if case let .success(image) = phase {
                            image.resizable().scaledToFit()
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                }
                Text(verbatim: group.title)
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 60)
        }

        private func hintRow(_ text: LocalizedStringKey, icon: String) -> some View {
            Label(text, systemImage: icon)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.55))
        }

        // MARK: - Focus

        /// Use the hero's leading action: Watch when a channel is known,
        /// Remind Me when a scheduled fixture is not yet in the guide; else its
        /// Match Centre, then the first card.
        private func defaultFocus(
            hero: SportsFixture?,
            availability: SportsChannelAvailability?,
            groups: [SportsFixtureGroup]
        ) -> TVSportsFocus? {
            if let hero {
                if availability?.isAvailable == true || hero.status.state == .scheduled {
                    return .heroWatch
                }
                return .heroDetail
            }
            return groups.first?.fixtures.first.map { TVSportsFocus.card($0.id) }
        }

        // MARK: - Playback

        func watch(_ channel: ResolvedChannel) {
            guard let media = SportsPlayback.media(for: channel, in: modelContext) else { return }

            if selectedFixture != nil {
                // Presented from the detail cover's `onDismiss`: a cover put up
                // while another is still animating out is torn down and
                // re-presented, opening the stream twice and tripping the
                // provider's connection cap. See `presentPendingMedia`.
                pendingMedia = media
                selectedFixture = nil
            } else {
                playingMedia = media
            }
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
            playingMedia = media
        }

        /// Catch-up from kickoff for a live game under Hide Scores.
        private func fromStartMedia(_ fixture: SportsFixture, availability: SportsChannelAvailability) -> PlayableMedia? {
            guard hidesScores, fixture.isInProgress, case let .available(_, best) = availability else { return nil }
            return SportsPlayback.fromStartMedia(for: best, fixture: fixture, in: modelContext)
        }

        private func presentPendingMedia() {
            guard let media = pendingMedia else { return }
            pendingMedia = nil
            playingMedia = media
        }
    }

    private extension TVSportsHubScreen {
        // MARK: - Lifecycle

        func onAppear() {
            store.loadCached(leagueIds: displayLeagueIds)
            SportsSyncService.shared.refreshIfStale()
            SportsSyncService.shared.beginLivePolling()
        }

        func resolveKey(_ fixtures: [SportsFixture]) -> String {
            fixtures.map(\.id).joined(separator: ",") + "|" + String(epg.isSyncing)
        }

        func runResolve(_ fixtures: [SportsFixture]) async {
            guard !fixtures.isEmpty else {
                resolved = [:]
                return
            }
            await SportsChannelResolver.resolveSoonestFirst(
                container: modelContext.container,
                fixtures: fixtures,
                restriction: restriction,
                publish: { resolved = $0 }
            )
        }

        var heroSelectionContext: String {
            let scopeToken = switch scope {
            case .all: "all"
            case let .follow(key): "follow:\(key)"
            }
            let followsToken = follows.follows
                .map { "\($0.kind.rawValue):\($0.key)" }
                .sorted()
                .joined(separator: ",")
            return "\(scopeToken)|\(followsToken)"
        }

        func heroSelectionKey(for candidates: [SportsHeroSelectionMachine.Candidate]) -> String {
            let candidatesToken = candidates
                .map { "\($0.id):\($0.tier.rawValue):\($0.isAvailable)" }
                .joined(separator: ",")
            return "\(heroSelectionContext)|\(candidatesToken)"
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
            let fixtures = grouping.pageFixtures(season: pageSeason)
            let preference = SportsChannelPreference.Context.current
            return ScrollViewReader { proxy in
                CategoryPage(title: scopeTitle) {
                    Color.clear.frame(height: 0).id(Self.pageTop)
                    if fixtures.isEmpty {
                        // A line, not a screenful: the season sits just below.
                        Text("No games")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.vertical, 24)
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
                                    selectedFixture = fixture
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 24)
                    }
                    if let team = seasonTeam {
                        // On the page's own inset, so it lines up with the heading
                        // and grid above.
                        TVTeamSeasonSection(
                            teams: [team],
                            horizontalInset: nil,
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
                pageSeason = await SportsTeamSeasonLoader.load(team: team)
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
