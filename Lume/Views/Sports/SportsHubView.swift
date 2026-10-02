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
//  scope Menu switches between "My Teams" and a single followed league; the
//  segmented control walks Yesterday / Today / Upcoming.
//

import SwiftData
import SwiftUI

/// What the hub is scoped to: every followed league/team, or one league.
enum SportsHubScope: Hashable {
    case myTeams
    case league(String)
}

/// The time window the segmented control selects.
enum SportsHubSegment: String, CaseIterable, Identifiable {
    case yesterday
    case today
    case upcoming

    var id: String {
        rawValue
    }

    var title: LocalizedStringKey {
        switch self {
        case .yesterday: "Yesterday"
        case .today: "Today"
        case .upcoming: "Upcoming"
        }
    }
}

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

    @State private var scope: SportsHubScope = .myTeams
    @State private var segment: SportsHubSegment = .today
    @State private var resolved: [String: [ResolvedChannel]] = [:]
    @State private var heroSelection = SportsHeroSelectionMachine()
    @State private var highlightsLoad = SportsHighlightsLoadMachine()
    @State private var selectedFixture: SportsFixture?
    @State private var pickerFixture: SportsFixture?
    @State private var showManageTeams = false
    @State private var showingBrowse = false
    @State private var showPaywall = false
    @State private var localPath = NavigationPath()
    #if os(iOS) || os(visionOS)
        @State private var playingMedia: PlayableMedia?
        /// Playback queued behind a dismissing sheet; see `present(_:afterSheet:)`.
        @State private var pendingMedia: PlayableMedia?
    #endif

    var body: some View {
        let fixtures = premium.isPremium ? visibleFixtures : []
        NavigationStack(path: pathBinding) {
            Group {
                if premium.isPremium {
                    hubContent(fixtures)
                } else {
                    lockedState
                }
            }
            .overlay(alignment: .leading) {
                if premium.isPremium {
                    SportsBrowseSidebar(
                        isPresented: $showingBrowse,
                        leagues: followedLeagues,
                        scope: scope,
                        onSelect: { value in
                            scope = value
                            showingBrowse = false
                        },
                        onManageTeams: {
                            showingBrowse = false
                            showManageTeams = true
                        }
                    )
                }
            }
            .platformNavigationTitle("Sports")
            .hubInlineNavigationTitle()
            .navigationDestination(for: SportsLeague.self) { league in
                LeagueDetailView(league: league)
            }
            .toolbar { if premium.isPremium { hubToolbar } }
            .browseSidebarToolbar(isPresented: $showingBrowse, isEnabled: premium.isPremium)
            .sheet(isPresented: $showManageTeams) { ManageTeamsSheet() }
            .sheet(item: $selectedFixture, onDismiss: presentPendingMedia) { fixture in
                GameDetailSheet(fixture: fixture, resolved: resolved[fixture.id] ?? [], onWatch: watch)
            }
            .sheet(item: $pickerFixture, onDismiss: presentPendingMedia) { fixture in
                ChannelPickerSheet(fixture: fixture, resolved: resolved[fixture.id] ?? [], onWatch: watch)
            }
            .paywall(isPresented: $showPaywall, highlight: .sportsHub)
            #if os(iOS) || os(visionOS)
                .fullScreenCover(item: $playingMedia) { media in
                    FullScreenPlayerView(media: media)
                }
            #endif
        }
        .profileMenuToolbar()
        .onAppear(perform: onAppear)
        .onDisappear { SportsSyncService.shared.endLivePolling() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var hubToolbar: some ToolbarContent {
        // The scope is picked from the browse panel Movies and Live TV use;
        // the title names it and opens it too.
        ToolbarItem(placement: .principal) {
            Button {
                showingBrowse.toggle()
            } label: {
                Text(scopeTitle).font(.headline)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Choose leagues"))
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showManageTeams = true
            } label: {
                Label("Manage Teams", systemImage: "person.2.badge.plus")
            }
        }
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
            } else {
                followedContent(fixtures)
            }
        }
        .task(id: follows.follows.map(\.key)) { await loadHighlights() }
    }

    /// Big this week, less whichever pick is already the headline.
    @ViewBuilder
    private func highlightsRail(excluding heroId: String? = nil) -> some View {
        let highlights = highlightsLoad.result
        let picks = highlights.highlights.filter { $0.fixture.id != heroId }
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

    /// Followed football teams, for the season panel.
    private var seasonTeams: [SportsTeam] {
        follows.follows
            .filter { $0.kind == .team }
            .compactMap { store.team(by: $0.key) }
            .filter(SportsTeamSeasonLoader.supports)
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
            in: fixtures, fallback: highlightsLoad.result.highlights.first?.fixture, availableIDs: heroAvailableIDs
        )
        let hero = heroSelection.displayed(in: candidates, context: heroSelectionContext)?.fixture
        return VStack(spacing: 0) {
            Picker("Range", selection: $segment) {
                ForEach(SportsHubSegment.allCases) { segment in
                    Text(segment.title).tag(segment)
                }
            }
            .hubSegmentedPickerStyle()
            .padding(.horizontal)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    statusHints
                    heroCard(hero)
                    SportsSectionsView(
                        // The headlined game leads on its own, not again below.
                        groups: grouping.groups(for: fixtures.filter { $0.id != hero?.id }),
                        resolved: resolved,
                        isFollowed: isFollowed,
                        onOpenDetail: { selectedFixture = $0 },
                        onWatch: watch,
                        onFollowToggle: toggleFollow,
                        onPickChannel: { pickerFixture = $0 },
                        onSelectLeague: { scope = .league($0) }
                    )
                    if scope == .myTeams {
                        highlightsRail(excluding: hero?.id)
                        if !seasonTeams.isEmpty {
                            SportsTeamSeasonPanel(teams: seasonTeams)
                        }
                    }
                }
                .padding()
            }
        }
        // A headline from later in the week isn't on screen, but still wants
        // its channel once the guide reaches it.
        .task(id: resolveKey(fixtures + offScreen(hero, in: fixtures))) {
            await runResolve(fixtures + offScreen(hero, in: fixtures))
        }
        .task(id: heroSelectionKey(for: candidates)) {
            heroSelection.reconcile(candidates: candidates, context: heroSelectionContext)
        }
    }

    @ViewBuilder
    private func heroCard(_ hero: SportsFixture?) -> some View {
        if let hero {
            SportsHubHeroCard(
                fixture: hero,
                availability: SportsChannelAvailability(
                    resolved[hero.id] ?? highlightsLoad.result.resolved[hero.id],
                    startDate: hero.headlineDate,
                    preference: .current
                ),
                onWatch: watch,
                onOpen: { selectedFixture = hero }
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

    // MARK: - Navigation path

    private var pathBinding: Binding<NavigationPath> {
        if let router {
            return Binding(get: { router.sportsPath }, set: { router.sportsPath = $0 })
        }
        return $localPath
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
        fixtures.map(\.id).joined(separator: ",") + "|" + String(epg.isSyncing)
    }

    private var heroSelectionContext: String {
        let scopeToken = switch scope {
        case .myTeams: "myTeams"
        case let .league(id): "league:\(id)"
        }
        let followsToken = follows.follows
            .map { "\($0.kind.rawValue):\($0.key)" }
            .sorted()
            .joined(separator: ",")
        return "\(scopeToken)|\(segment.rawValue)|\(followsToken)"
    }

    private func heroSelectionKey(for candidates: [SportsHeroSelectionMachine.Candidate]) -> String {
        let candidatesToken = candidates
            .map { "\($0.id):\($0.tier.rawValue):\($0.isAvailable)" }
            .joined(separator: ",")
        return "\(heroSelectionContext)|\(candidatesToken)"
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

    private func watch(_ channel: ResolvedChannel) {
        guard let media = SportsPlayback.media(for: channel, in: modelContext) else { return }

        let hadSheet = selectedFixture != nil || pickerFixture != nil
        selectedFixture = nil
        pickerFixture = nil
        present(media, afterSheet: hadSheet)
    }

    private func watchEvent(_ event: SportsPayPerView.Event) {
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
                pendingMedia = media
            } else {
                playingMedia = media
            }
        #endif
    }

    private func presentPendingMedia() {
        #if os(iOS) || os(visionOS)
            guard let media = pendingMedia else { return }
            pendingMedia = nil
            playingMedia = media
        #endif
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
        SportsHubGrouping(scope: scope, segment: segment, follows: follows.follows, store: store)
    }

    private var displayLeagueIds: [String] {
        grouping.displayLeagueIds
    }

    private var followedLeagues: [SportsLeague] {
        grouping.followedLeagues
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

    /// The half-open date interval a segment covers, relative to `now`.
    static func dateRange(for segment: SportsHubSegment, now: Date, calendar: Calendar = .current) -> Range<Date> {
        let startOfToday = calendar.startOfDay(for: now)
        switch segment {
        case .yesterday:
            let start = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
            return start ..< startOfToday
        case .today:
            let end = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
            return startOfToday ..< end
        case .upcoming:
            let end = calendar.date(byAdding: .day, value: 7, to: startOfToday) ?? startOfToday
            return now ..< end
        }
    }

    /// Whether a fixture belongs under a segment. Today claims what is live or
    /// on at any point today, so an event that started last night and runs past
    /// midnight stays in Today; the other segments go by start.
    static func fixture(
        _ fixture: SportsFixture,
        isIn segment: SportsHubSegment,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        let range = dateRange(for: segment, now: now, calendar: calendar)
        switch segment {
        case .today:
            return fixture.isInProgress || fixture.isOn(during: range)
        case .yesterday, .upcoming:
            return range.contains(fixture.headlineDate)
        }
    }
}

#Preview {
    SportsHubView()
        .modelContainer(for: Playlist.self, inMemory: true)
}
