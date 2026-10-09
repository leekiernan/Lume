import SwiftData
import SwiftUI

struct LiveTVHubView: View {
    let playlistPrefix: String
    let syncedAt: Date?
    let onOpenBrowse: () -> Void
    let onOpenGuide: () -> Void
    let onPlay: (String, LiveChannelScope?) -> Void
    let onWatchFromStart: (String, EPGSlot) -> Void
    let onStartMultiView: (String) -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    @Environment(ProfileManager.self) private var profiles: ProfileManager?
    @Environment(\.scenePhase) private var scenePhase
    @Query private var favorites: [LiveStream]
    @Query private var recents: [LiveStream]
    @State private var feed = LiveTVHubFeed()
    @State private var epgSync = EPGSyncService.shared
    @State private var selectedProgramme: LiveTVHubProgramme?
    @AppStorage(LiveTVHubLayout.orderKey) private var sectionOrderRaw = ""
    @AppStorage(LiveTVHubLayout.hiddenKey) private var hiddenSectionsRaw = ""

    init(
        playlistPrefix: String, syncedAt: Date?, onOpenBrowse: @escaping () -> Void,
        onOpenGuide: @escaping () -> Void, onPlay: @escaping (String, LiveChannelScope?) -> Void,
        onWatchFromStart: @escaping (String, EPGSlot) -> Void, onStartMultiView: @escaping (String) -> Void
    ) {
        self.playlistPrefix = playlistPrefix
        self.syncedAt = syncedAt
        self.onOpenBrowse = onOpenBrowse
        self.onOpenGuide = onOpenGuide
        self.onPlay = onPlay
        self.onWatchFromStart = onWatchFromStart
        self.onStartMultiView = onStartMultiView
        _favorites = Query(LiveChannelQuery.descriptor(for: .favorites, sort: .playlist))
        _recents = Query(LiveChannelQuery.descriptor(for: .recentlyWatched, sort: .playlist))
    }

    private var favoriteChannels: [LiveStream] {
        Array(LiveChannelQuery.scoped(favorites, scope: .favorites, playlistPrefix: playlistPrefix, restriction: restriction)
            .prefix(LiveTVHubPolicy.railLimit))
    }

    private var recentChannels: [LiveStream] {
        Array(LiveChannelQuery.scoped(recents, scope: .recentlyWatched, playlistPrefix: playlistPrefix, restriction: restriction)
            .prefix(LiveTVHubPolicy.railLimit))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let now = timeline.date
            let key = LiveTVHubFeed.Key(
                prefix: playlistPrefix, visibility: restriction.visibilityToken,
                profile: profileToken,
                syncedAt: syncedAt, guideRevision: epgSync.readRevision, isActive: scenePhase == .active,
                hour: Int(now.timeIntervalSince1970 / 3600), personalIDs: (favoriteChannels + recentChannels).map(\.id)
            )
            page(now: now)
                .task(id: key) {
                    guard scenePhase == .active else { return }
                    epgSync.ensureCoverage(reason: "Live TV hub")
                    await feed.load(key: key, restriction: restriction, container: modelContext.container, now: now)
                }
                .task(id: "\(key)-\(Int(now.timeIntervalSince1970 / 60))-\(snapshot.collections.map(\.id))") {
                    guard scenePhase == .active else { return }
                    let channels = (favoriteChannels + recentChannels).map(channel) + snapshot.collections.flatMap(\.channels)
                    await feed.refreshEPG(channelIDs: Array(Set(channels.compactMap(\.epgID))), container: modelContext.container,
                                          prefix: playlistPrefix, visibility: restriction.visibilityToken, profile: profileToken)
                }
        }
        .background { LumeAmbientBackground() }
        .browseActivity()
        .sheet(item: $selectedProgramme) { programme in programmeDetail(programme) }
        .onChange(of: profileToken) { selectedProgramme = nil }
    }

    private var profileToken: String {
        (profiles?.activeProfileID ?? ActiveProfileStore.current)?.uuidString ?? ""
    }

    private var snapshot: LiveTVHubSnapshot {
        feed.snapshot(prefix: playlistPrefix, visibility: restriction.visibilityToken, profile: profileToken)
    }

    @ViewBuilder private func page(now: Date) -> some View {
        let heroes = heroProgrammes(now: now)
        #if os(tvOS)
            TVLiveTVHubPage(heroes: heroes, now: now, onPlay: watch, onInfo: { selectedProgramme = $0 }, rows: {
                rows(now: now)
            })
        #else
            HeroFeedLayout(reservesHero: !heroes.isEmpty, hero: {
                if !heroes.isEmpty {
                    HeroCarousel(items: heroes, imageURL: { $0.artworkURL.flatMap(URL.init(string:)) }, backdrop: { hero in
                        LiveTVHubBackdrop(programme: hero)
                    }, info: { hero, compact in
                        LiveTVHubHeroInfo(programme: hero, now: now, isCompact: compact,
                                          onPlay: { watch(hero) }, onInfo: { selectedProgramme = hero })
                    })
                }
            }, rows: { rows(now: now) })
        #endif
    }

    @ViewBuilder private func rows(now: Date) -> some View {
        HStack {
            Button(action: onOpenGuide) { Label("Guide", systemImage: "tablecells") }
            Spacer()
            if feed.isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal)
        ForEach(LiveTVHubLayout.rows(orderRaw: sectionOrderRaw, hiddenRaw: hiddenSectionsRaw)) { row in
            sectionRow(row, now: now)
        }
        BrowseCategoriesButton(onOpen: onOpenBrowse)
    }

    @ViewBuilder private func sectionRow(_ row: LiveTVHubRow, now: Date) -> some View {
        switch row {
        case .recentlyWatched:
            if !recentChannels.isEmpty { personalRail(recentChannels, section: .recentlyWatched, now: now) }
        case .favorites:
            if !favoriteChannels.isEmpty { personalRail(favoriteChannels, section: .favorites, now: now) }
        case .startingSoon:
            programmeRail(title: Text(verbatim: row.title), programmes: LiveTVHubPolicy.discovery(snapshot.programmes, now: now, liveOnly: false), now: now)
        default:
            if let collection = snapshot.collections.first(where: { $0.id == row.id }) {
                let section = LiveTVSection.collection(id: collection.id, title: collection.title, channelIDs: collection.channels.map(\.id))
                channelRail(collection.channels, section: section, now: now)
            }
        }
    }

    private func personalRail(_ streams: [LiveStream], section: LiveTVSection, now: Date) -> some View {
        channelRail(streams.map(channel), section: section, now: now)
    }

    private func channelRail(_ channels: [LiveTVHubChannel], section: LiveTVSection, now: Date) -> some View {
        PosterRail(title: section.titleText, showAll: section, groupsFocus: true, rowHeight: LiveTVHubCard.height + 56) {
            ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                let current = slot(for: channel, now: now)
                Button { onPlay(channel.id, section.scope) } label: {
                    LiveTVHubCard(channel: channel, slot: current, now: now)
                }
                .liveTVHubCardStyle()
                .onLeadingEdgeLeft(index == 0 ? onOpenBrowse : nil)
                .liveChannelMenu(
                    isFavorite: isFavorite(channel), onToggleFavorite: { toggleFavorite(channel) },
                    onWatchFromStart: channel.catchupDays > 0 ? current.map { slot in { onWatchFromStart(channel.id, slot) } } : nil,
                    onStartMultiView: { onStartMultiView(channel.id) },
                    onRemoveFromRecents: section.scope == .recentlyWatched ? { removeFromRecents(channel) } : nil
                )
            }
        }
    }

    @ViewBuilder private func programmeRail(title: Text, programmes: [LiveTVHubProgramme], now: Date) -> some View {
        if !programmes.isEmpty {
            PosterRail<LiveTVSection, _>(title: title, showAll: nil, groupsFocus: true, rowHeight: LiveTVHubCard.height + 56) {
                ForEach(programmes) { programme in
                    Button { selectedProgramme = programme } label: {
                        LiveTVHubCard(channel: programme.channel,
                                      slot: EPGSlot(title: programme.title, start: programme.start, end: programme.end, artworkURL: programme.artworkURL),
                                      now: now, programmeArtwork: true)
                    }
                    .liveTVHubCardStyle()
                }
            }
        }
    }

    private func heroProgrammes(now: Date) -> [LiveTVHubProgramme] {
        let discovered = LiveTVHubPolicy.discovery(snapshot.programmes, now: now, liveOnly: true)
        if !discovered.isEmpty { return Array(discovered.prefix(5)) }
        let channels = (favoriteChannels + recentChannels).map(channel) + snapshot.collections.flatMap(\.channels)
        var seen: Set<String> = []
        return Array(channels.compactMap { channel -> LiveTVHubProgramme? in
            guard seen.insert(channel.id).inserted, let slot = slot(for: channel, now: now) else { return nil }
            return LiveTVHubProgramme(id: "\(channel.id)-\(slot.start.timeIntervalSince1970)", channel: channel,
                                      title: slot.title, start: slot.start, end: slot.end, artworkURL: slot.artworkURL,
                                      overview: "", candidateID: nil, rank: 0)
        }.prefix(5))
    }

    private func slot(for channel: LiveTVHubChannel, now: Date) -> EPGSlot? {
        guard let epg = snapshot.epg[channel.epgID ?? ""] else { return nil }
        return [epg.current, epg.next].compactMap(\.self).first { $0.start <= now && now < $0.end }
    }

    private func watch(_ programme: LiveTVHubProgramme) {
        guard programme.isLive(at: .now) else { return }
        onPlay(programme.channel.id, heroScope(for: programme))
    }

    private func heroScope(for programme: LiveTVHubProgramme) -> LiveChannelScope {
        let discovered = LiveTVHubPolicy.discovery(snapshot.programmes, now: .now, liveOnly: true).map(\.channel.id)
        let ids = discovered.contains(programme.channel.id) ? discovered : heroProgrammes(now: .now).map(\.channel.id)
        return .channels(ids.contains(programme.channel.id) ? ids : [programme.channel.id])
    }

    private func channel(_ stream: LiveStream) -> LiveTVHubChannel {
        .init(id: stream.id, name: stream.name, logoURL: stream.streamIcon, epgID: stream.epgChannelId, isFavorite: stream.isFavorite,
              catchupDays: stream.supportsCatchup ? stream.catchupArchiveDays : 0)
    }

    private func stream(_ id: String) -> LiveStream? {
        LiveTVHubSelection.stream(id, prefix: playlistPrefix, restriction: restriction, in: modelContext)
    }

    private func isFavorite(_ channel: LiveTVHubChannel) -> Bool {
        stream(channel.id)?.isFavorite ?? channel.isFavorite
    }

    private func toggleFavorite(_ channel: LiveTVHubChannel) {
        if let stream = stream(channel.id) { LiveChannelFavorites.toggle(stream, in: modelContext) }
    }

    private func removeFromRecents(_ channel: LiveTVHubChannel) {
        if let stream = stream(channel.id) { LiveChannelHistory.removeFromRecents(stream, in: modelContext) }
    }

    @ViewBuilder private func programmeDetail(_ programme: LiveTVHubProgramme) -> some View {
        if let stream = stream(programme.channel.id) {
            EPGProgramDetailView(stream: stream,
                                 cell: EPGProgramCell(id: programme.id, title: programme.title, detail: programme.overview,
                                                      start: programme.start, end: programme.end,
                                                      listingID: programme.id, isGap: false, width: 0),
                                 now: .now, onPlay: { onPlay(programme.channel.id, heroScope(for: programme)) }, onPlayCatchup: {
                                     onWatchFromStart(programme.channel.id, EPGSlot(title: programme.title, start: programme.start, end: programme.end))
                                 })
        }
    }
}
