//
//  TVSportsHubScreen.swift
//  Lume
//
//  The tvOS Sports Hub. The phone hub's segmented control and toolbar do not
//  read on a remote, so this is a purpose-built 10-foot screen: one scrolling
//  page whose header is the scope menu drawn as the page title, a compact
//  Yesterday / Today / Upcoming switch and an icon-only Manage Teams button,
//  then full-width horizontal rails of `TVFixtureLogoCard`s, one focus section
//  per group. The header scrolls with the page — a pinned bar over an unclipped
//  scroll view had the cards sliding underneath it. It shares the hub's data
//  plumbing — `SportsStore` snapshots, `SportsFollowService` follows, off-main
//  `SportsChannelResolver` — and reuses `SportsHubView`'s static date/assembly
//  helpers so the two hubs stay in step.
//

#if os(tvOS)

    import SwiftData
    import SwiftUI

    /// Focus targets on the hub, so Menu (exit) from a card can return focus to
    /// the filter row rather than dropping to the tab bar mid-browse.
    enum TVSportsFocus: Hashable {
        case scope
        case segment(SportsHubSegment)
        case manage
        case heroWatch
        case heroDetail
        case card(String)
    }

    /// The filters are one lazy-stack child. Their individual buttons may be
    /// released while a lower rail is focused, so return focus via this stable
    /// container rather than an individual segment's identity.
    private enum TVSportsScrollTarget: Hashable {
        case filters
    }

    struct TVSportsHubScreen: View {
        @Environment(\.modelContext) var modelContext
        @Environment(\.contentRestriction) var restriction

        @State private var premium = PremiumManager.shared
        @State private var store = SportsStore.shared
        @State var follows = SportsFollowService.shared
        @State private var epg = EPGSyncService.shared

        @State var scope: SportsHubScope = .myTeams
        /// The scope panel, and where focus was when it opened.
        @State var showingBrowse = false
        @State var browseReturnFocus: TVSportsFocus?
        @State private var segment: SportsHubSegment = .today
        @State private var resolved: [String: [ResolvedChannel]] = [:]
        @State var selectedFixture: SportsFixture?
        @State var showManageTeams = false
        @State private var showPaywall = false
        @State private var playingMedia: PlayableMedia?
        /// Playback queued behind the dismissing detail cover; see `watch`.
        @State private var pendingMedia: PlayableMedia?
        @AppStorage(SportsSyncService.hideScoresKey) private var hidesScores = false
        /// The headlined game from its first minute, when Hide Scores is on and
        /// the channel can replay it — worked out once per game, not per render.
        @State private var heroFromStart: PlayableMedia?
        /// "Big this week", and the channels its near-term games resolved to.
        @State var highlightsLoad = SportsHighlightsLoadMachine()

        @FocusState var focus: TVSportsFocus?

        var body: some View {
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
                } else {
                    content
                        .overlay(alignment: .leading) { browseSidebar }
                }
            }
            .task(id: follows.follows.map(\.key)) { await loadHighlights() }
        }

        /// The whole hub is one scrolling page so the header can never sit over
        /// the cards: title-style scope menu on the left, the day switch and the
        /// Manage Teams button on the right, then the rails.
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
            let hero = grouping.heroFixture(
                in: fixtures, fallback: highlightsLoad.result.highlights.first?.fixture, availableIDs: availableIDs
            )
            // Big this week leaves out whichever pick is already the headline.
            let highlights = highlightsLoad.result.highlights.filter { $0.fixture.id != hero?.id }
            // The headlined game leads the page on its own, not again in a rail.
            let groups = grouping.groups(for: fixtures.filter { $0.id != hero?.id })
            let heroAvailability = hero.map {
                SportsChannelAvailability(
                    resolved[$0.id] ?? highlightsLoad.result.resolved[$0.id], startDate: $0.headlineDate, preference: preference
                )
            }
            // A headline from later in the week isn't on screen, but still
            // wants its channel once the guide reaches it.
            let toResolve = fixtures + [hero].compactMap(\.self).filter { hero in !fixtures.contains { $0.id == hero.id } }
            return ScrollViewReader { scrollProxy in
                ScrollView {
                    ZStack(alignment: .top) {
                        if let hero {
                            TVSportsHubHeroBackdrop(fixture: hero)
                        }
                        LazyVStack(alignment: .leading, spacing: 36) {
                            header
                            if let hero, let heroAvailability {
                                TVSportsHubHero(
                                    fixture: hero,
                                    availability: heroAvailability,
                                    showsScore: hero.showsScore(hidingScores: hidesScores, reveal: SportsScoreReveal.shared),
                                    watchFocus: $focus,
                                    onWatch: watch,
                                    onWatchFromStart: heroFromStart.map { media in { playingMedia = media } },
                                    onOpen: { selectedFixture = hero },
                                    onLeadingLeft: openBrowse
                                )
                                .padding(.vertical, 24)
                                .task(id: "\(hero.id)|\(hidesScores)|\(heroAvailability.isAvailable)") {
                                    heroFromStart = fromStartMedia(hero, availability: heroAvailability)
                                }
                            }
                            if groups.isEmpty, hero == nil {
                                noGamesState
                            } else {
                                ForEach(groups) { group in
                                    section(for: group, preference: preference, scrollProxy: scrollProxy)
                                }
                            }
                            if scope == .myTeams, !highlights.isEmpty || !highlightsLoad.result.payPerView.isEmpty {
                                TVSportsHighlightsSection(
                                    highlights: highlights,
                                    payPerView: highlightsLoad.result.payPerView,
                                    availability: highlightAvailability,
                                    onSelect: { selectedFixture = $0 },
                                    onWatchEvent: watchEvent
                                )
                                .padding(.top, 24)
                            }
                            if scope == .myTeams, !seasonTeams.isEmpty {
                                TVTeamSeasonSection(teams: seasonTeams)
                                    .padding(.top, 24)
                            }
                        }
                        // The native tab chrome is the next focus target above
                        // this screen. Match Settings' top breathing room so an
                        // exit from the filters has an unambiguous spatial route
                        // to it; at 20pt the controls sat inside that region and
                        // trapped focus inside the scroll view.
                        .padding(.top, 72)
                        .padding(.bottom, 40)
                    }
                }
                .scrollClipDisabled()
                .defaultFocus($focus, defaultFocus(hero: hero, availability: heroAvailability, groups: groups))
                .task(id: resolveKey(toResolve)) { await runResolve(toResolve) }
            }
        }

        // MARK: - Header

        /// The scope menu reads as the page title; the controls to its right
        /// stay quiet at rest — only the active day carries a fill — so the row
        /// reads as a heading, not a toolbar. Status hints sit under the title.
        private var header: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 24) {
                    scopeMenu
                    Spacer(minLength: 24)
                    segmentedControl
                    manageButton
                }
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
            .focusSection()
            .id(TVSportsScrollTarget.filters)
        }

        // MARK: - Filter controls

        private var segmentedControl: some View {
            HStack(spacing: 4) {
                ForEach(SportsHubSegment.allCases) { segment in
                    segmentButton(segment)
                }
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.08))
            )
        }

        private func segmentButton(_ value: SportsHubSegment) -> some View {
            let isActive = segment == value
            let isItemFocused = focus == .segment(value)
            return Button {
                segment = value
            } label: {
                TVSportsPillLabel(
                    title: value.title,
                    font: .callout.weight(.semibold),
                    isFocused: isItemFocused,
                    isActive: isActive,
                    horizontalPadding: 22,
                    verticalPadding: 12,
                    cornerRadius: 12
                )
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.03))
            .focused($focus, equals: .segment(value))
            .animation(.easeOut(duration: 0.18), value: isItemFocused)
        }

        /// The page title; selecting it, or pressing left from the page's
        /// leading edge, opens the scope panel.
        private var scopeMenu: some View {
            Button(action: openBrowse) {
                TVSportsTitleChrome {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                        Text(verbatim: scopeTitle)
                            .font(.system(size: 34, weight: .bold))
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.02))
            .focused($focus, equals: .scope)
            .onLeadingEdgeLeft(openBrowse)
            .accessibilityLabel(Text(verbatim: scopeTitle))
            .accessibilityHint(Text("Choose leagues"))
        }

        private var manageButton: some View {
            Button {
                showManageTeams = true
            } label: {
                TVSportsCircleChrome {
                    Image(systemName: "person.2.badge.plus")
                        .font(.system(size: 26, weight: .semibold))
                }
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.06))
            .focused($focus, equals: .manage)
            .accessibilityLabel(Text("Manage Teams"))
        }

        // MARK: - Sections

        /// The heading matches `HomeRow`'s — subheadline, bold, secondary — so
        /// the hub's rails read like every other rail on the tvOS Home.
        private func section(
            for group: SportsFixtureGroup,
            preference: SportsChannelPreference.Context,
            scrollProxy: ScrollViewProxy
        ) -> some View {
            VStack(alignment: .leading, spacing: 12) {
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
                            // A card owns the first Menu press: return to the
                            // filters and make their lazy header visible again.
                            // The filters deliberately have no exit handler, so
                            // their next Menu press can bubble to the tab bar.
                            .onExitCommand { returnFocusToFilter(using: scrollProxy) }
                        }
                    }
                    .padding(.horizontal, 60)
                    .padding(.vertical, 8)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }

        // MARK: - States

        private var onboardingState: some View {
            fullScreenState(
                title: "Follow Your Teams",
                message: "Add leagues and teams to see fixtures, live scores and standings, with one tap to the channel carrying the game."
            ) {
                Button {
                    showManageTeams = true
                } label: {
                    Label("Manage Teams", systemImage: "person.2.badge.plus")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 44)
                        .padding(.vertical, 20)
                }
                .buttonStyle(TVCardButtonStyle(focusScale: 1.05))
            }
        }

        private var lockedState: some View {
            fullScreenState(
                title: PremiumFeature.sportsHub.title,
                message: PremiumFeature.sportsHub.subtitle
            ) {
                Button {
                    showPaywall = true
                } label: {
                    Text("Unlock Sports Hub")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 44)
                        .padding(.vertical, 20)
                }
                .buttonStyle(TVCardButtonStyle(focusScale: 1.05))
            }
        }

        private var noGamesState: some View {
            VStack(spacing: 24) {
                Image(systemName: "sportscourt")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.35))
                Text("No games")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, minHeight: 560)
        }

        private func fullScreenState(
            title: LocalizedStringResource,
            message: LocalizedStringResource,
            @ViewBuilder action: () -> some View
        ) -> some View {
            VStack(spacing: 24) {
                Image(systemName: "sportscourt")
                    .font(.system(size: 80))
                    .foregroundStyle(.white.opacity(0.5))
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 820)
                action()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

        private func returnFocusToFilter(using scrollProxy: ScrollViewProxy) {
            Task { @MainActor in
                await landTVFocus(
                    $focus,
                    on: .segment(segment),
                    scrollingTo: scrollProxy,
                    scrollTarget: TVSportsScrollTarget.filters,
                    scrollAnchor: .top
                )
            }
        }

        // MARK: - Lifecycle

        private func onAppear() {
            store.loadCached(leagueIds: displayLeagueIds)
            SportsSyncService.shared.refreshIfStale()
            SportsSyncService.shared.beginLivePolling()
        }

        private func resolveKey(_ fixtures: [SportsFixture]) -> String {
            fixtures.map(\.id).joined(separator: ",") + "|" + String(epg.isSyncing)
        }

        private func runResolve(_ fixtures: [SportsFixture]) async {
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
        func watchEvent(_ event: SportsPayPerView.Event) {
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
        // MARK: - Follow

        private func isFollowed(_ team: SportsTeam) -> Bool {
            follows.isFollowing(team.id)
        }

        // MARK: - Fixture assembly

        /// The shared selection/grouping rules; the tvOS hub keeps only its chrome.
        private var grouping: SportsHubGrouping {
            SportsHubGrouping(scope: scope, segment: segment, follows: follows.follows, store: store)
        }

        private var displayLeagueIds: [String] {
            grouping.displayLeagueIds
        }

        private var followedLeagues: [SportsLeague] {
            grouping.followedLeagues
        }

        private var scopeTitle: String {
            grouping.scopeTitle
        }

        /// Followed football teams, for the season section.
        var seasonTeams: [SportsTeam] {
            follows.follows
                .filter { $0.kind == .team }
                .compactMap { store.team(by: $0.key) }
                .filter(SportsTeamSeasonLoader.supports)
        }
    }

    /// The page-title chrome for the scope menu: bare white text at rest, a soft
    /// wash when focused. A solid white fill here would turn the heading into a
    /// button and shout over the cards.
    private struct TVSportsTitleChrome<Content: View>: View {
        @ViewBuilder var content: () -> Content
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            content()
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(isFocused ? 0.16 : 0))
                )
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }

    /// A round icon-only control that shares the pills' rest wash and white
    /// focus fill, for actions that need no label at rest.
    private struct TVSportsCircleChrome<Content: View>: View {
        @ViewBuilder var content: () -> Content
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            content()
                .foregroundStyle(isFocused ? .black : .white)
                .frame(width: 64, height: 64)
                .background(Circle().fill(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.1))))
        }
    }

#endif
