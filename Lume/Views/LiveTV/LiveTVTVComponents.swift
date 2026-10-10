//
//  LiveTVTVComponents.swift
//  Lume
//
//  tvOS-only Live TV browsing components: the content controls and the large,
//  focusable channel list with inline now/next EPG. Split out from LiveTVView
//  to keep that file focused on cross-platform composition.
//

#if os(tvOS)
    import SwiftData
    import SwiftUI

    // MARK: - tvOS Channels List

    struct TVChannelsList: View {
        let scope: LiveChannelScope
        let playlistPrefix: String
        /// Opens the browse panel, naming the channel focus is leaving so it
        /// can be returned to. Nil when the press came from the clear button.
        let onLeadingLeft: (String?) -> Void
        /// The active playlist's source, so an empty list can say *why* it is
        /// empty rather than tell a WebDAV user to sync again.
        let sourceType: PlaylistSourceType?
        /// Seeds Multi-View with this channel, gated on Lume Pro by the host.
        let onStartMultiView: (LiveStream) -> Void
        /// Replays the programme on air from its start, via catch-up.
        let onWatchFromStart: (LiveStream, EPGSlot) -> Void
        let onPlay: (LiveStream) -> Void
        @Environment(\.modelContext) private var modelContext
        /// Drops channels in categories locked away from a child profile — the
        /// iOS list has always done this; this one didn't, so Favorites and
        /// Recently Watched still surfaced them here.
        @Environment(\.contentRestriction) private var restriction
        @Query private var streams: [LiveStream]
        /// Now/next EPG for the visible channels, resolved in one off-main fetch
        /// (see `ChannelEPGSnapshot`) instead of a per-row `@Query`.
        @State private var epgLoad = ChannelEPGLoadMachine()
        /// Observed so the EPG lookup refreshes when a guide import finishes.
        @State private var epgSync = EPGSyncService.shared
        /// How many channels are currently rendered. Grows by a page as the list
        /// nears its end so a large category loads lazily instead of all at once.
        @State private var visibleCount = LiveChannelQuery.pageSize
        /// Drives the "Clear Recently Watched" confirmation alert.
        @State private var confirmingClear = false
        /// Category names for Recently Watched and Favorites (`showsCategoryLabels`),
        /// keyed by category id; empty inside a category.
        @State private var categoryNames: [String: String] = [:]

        let focusRequest: TVContentFocusRequest?
        let onDidClaimFocus: (TVContentFocusRequest) -> Void

        @FocusState private var focusedChannelID: String?

        init(
            scope: LiveChannelScope,
            playlistPrefix: String,
            onLeadingLeft: @escaping (String?) -> Void,
            sourceType: PlaylistSourceType?,
            onStartMultiView: @escaping (LiveStream) -> Void,
            onWatchFromStart: @escaping (LiveStream, EPGSlot) -> Void,
            onPlay: @escaping (LiveStream) -> Void,
            focusRequest: TVContentFocusRequest? = nil,
            onDidClaimFocus: @escaping (TVContentFocusRequest) -> Void = { _ in }
        ) {
            self.scope = scope
            self.playlistPrefix = playlistPrefix
            self.onLeadingLeft = onLeadingLeft
            self.sourceType = sourceType
            self.onStartMultiView = onStartMultiView
            self.onWatchFromStart = onWatchFromStart
            self.onPlay = onPlay
            self.focusRequest = focusRequest
            self.onDidClaimFocus = onDidClaimFocus
            _streams = Query(LiveChannelQuery.descriptor(for: scope, sort: .playlist))
        }

        private var scopedStreams: [LiveStream] {
            LiveChannelQuery.scoped(streams, scope: scope, playlistPrefix: playlistPrefix, restriction: restriction)
        }

        var body: some View {
            let channels = scopedStreams
            let visible = Array(channels.prefix(visibleCount))
            let focusScope = TVContentFocusRequest.Scope(playlistPrefix: playlistPrefix, channelScope: scope, visibilityToken: restriction.visibilityToken)
            let landing = focusRequest?.landing(in: focusScope, channelIDs: channels.map(\.id))
            let epgScope = ChannelEPGLoadMachine.Scope(
                playlistPrefix: playlistPrefix, visibilityToken: restriction.visibilityToken, channelScope: scope
            )
            let epgKey = ChannelEPGLoadMachine.Key(
                scope: epgScope,
                refresh: .init(channelIDs: Set(channels.compactMap(\.epgChannelId)), revision: epgSync.readRevision, minute: epgSync.clockMinute),
                visibleChannelIDs: Set(visible.compactMap(\.epgChannelId))
            )
            let epgByChannel = epgLoad.snapshot(for: epgScope)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if channels.isEmpty {
                            LiveTVEmptyState(
                                sourceType: sourceType, playlistPrefix: playlistPrefix, restriction: restriction,
                                scope: scope, emptyDescription: "This category has no channels"
                            )
                            .padding(.top, 80)
                        } else {
                            if scope == .recentlyWatched {
                                clearButton
                                    .onLeadingEdgeLeft { onLeadingLeft(nil) }
                            }
                            ForEach(visible) { stream in
                                TVChannelRow(
                                    stream: stream,
                                    epg: epgByChannel[stream.epgChannelId ?? ""],
                                    categoryName: stream.categoryId.flatMap { categoryNames[$0] },
                                    onRemove: scope == .recentlyWatched ? { removeFromRecentlyWatched(stream) } : nil,
                                    onStartMultiView: { onStartMultiView(stream) },
                                    onWatchFromStart: { onWatchFromStart(stream, $0) },
                                    onPlay: { onPlay(stream) }
                                )
                                .onLeadingEdgeLeft { onLeadingLeft(stream.id) }
                                .focused($focusedChannelID, equals: stream.id)
                                .onAppear {
                                    if stream.id == visible.last?.id, visibleCount < channels.count {
                                        visibleCount = min(visibleCount + LiveChannelQuery.pageSize, channels.count)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, TVLayoutMetrics.contentInset)
                    .padding(.vertical, 40)
                }
                .focusSection()
                // Coming back from the browse panel, focus returns to the
                // channel it left. A new category is a new list with no such
                // position, so that starts at the top. Either way it is said
                // explicitly — the old rows are gone and the engine would be
                // left to guess.
                .task(id: landing) {
                    guard let landing, let focusRequest else { return }
                    visibleCount = max(visibleCount, landing.minimumVisibleCount)
                    await Task.yield()
                    if await landTVFocus($focusedChannelID, on: landing.channelID, scrollingTo: proxy) {
                        onDidClaimFocus(focusRequest)
                    }
                }
            }
            .completingEmptyTVFocus(focusRequest, scope: focusScope, hasChannels: !channels.isEmpty, onComplete: onDidClaimFocus)
            // Reload when the visible window or channel set changes, or a guide
            // import settles — EPG is resolved only for the channels on screen.
            .task(id: Set(channels.compactMap(\.categoryId))) {
                guard scope.showsCategoryLabels else { return }
                categoryNames = LiveCategoryNames.names(for: channels, in: modelContext)
            }
            .task(id: epgKey) {
                await ChannelEPGLoading.run(key: epgKey, machine: $epgLoad, container: modelContext.container)
            }
            .alert("Clear Recently Watched", isPresented: $confirmingClear) {
                Button("Clear", role: .destructive) { clearRecentlyWatched() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears the list of channels you've recently watched. Your favorites and the channels themselves aren't affected.")
            }
        }

        /// A full-width focusable "Clear" pill pinned above the Recently Watched
        /// rows. Full-width so the focus engine reliably catches a "down" move
        /// into it from the controls and out of it into the first channel.
        private var clearButton: some View {
            Button(role: .destructive) {
                confirmingClear = true
            } label: {
                Label("Clear Recently Watched", systemImage: "trash")
                    .font(.system(size: 28, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.02))
        }

        /// Clears a channel's watch timestamp so it drops out of the Recently
        /// Watched list. The @Query-backed list updates once the change is saved.
        private func removeFromRecentlyWatched(_ stream: LiveStream) {
            LiveChannelHistory.removeFromRecents(stream, in: modelContext)
        }

        /// Empties the whole Recently Watched list for the active playlist. The
        /// section drops away on its own once the last timestamp clears (its
        /// parent gates it on `hasRecents`).
        private func clearRecentlyWatched() {
            let container = modelContext.container
            Task { await StorageManager.clearRecentlyWatchedChannels(playlistPrefix: playlistPrefix, container: container) }
        }
    }

    /// One channel in the tvOS Live TV list — and in search results, which
    /// show channels the same way.
    struct TVChannelRow: View {
        let stream: LiveStream
        /// The channel's now/next programmes, resolved once by the parent list
        /// (see `ChannelEPGSnapshot`) rather than by a per-row `@Query`.
        var epg: ChannelEPG?
        /// Shown above the name in lists that mix categories.
        var categoryName: String?
        /// A programme still to come, shown in place of now/next — a search
        /// result for something on later.
        var upcoming: EPGSlot?
        var onRemove: (() -> Void)?
        var onStartMultiView: (() -> Void)?
        var onWatchFromStart: ((EPGSlot) -> Void)?
        let onPlay: () -> Void

        @Environment(\.modelContext) private var modelContext
        @FocusState private var isFocused: Bool

        private var currentEPG: EPGSlot? {
            epg?.current
        }

        var body: some View {
            Button(action: onPlay) {
                LiveChannelRowContent(stream: stream, epg: epg, categoryName: categoryName, upcoming: upcoming, density: .television)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(isFocused ? AnyShapeStyle(.white.opacity(0.18)) : AnyShapeStyle(.white.opacity(0.06)))
                    )
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.03))
            .focused($isFocused)
            .animation(.easeOut(duration: 0.18), value: isFocused)
            .liveChannelMenu(
                isFavorite: stream.isFavorite,
                onToggleFavorite: { LiveChannelFavorites.toggle(stream, in: modelContext) },
                onWatchFromStart: onWatchFromStart.flatMap { perform in
                    LiveChannelRestart.action(for: stream, current: currentEPG, perform: perform)
                },
                onStartMultiView: onStartMultiView,
                onRemoveFromRecents: onRemove
            )
        }
    }

    // MARK: - tvOS Live TV screen

    /// The unified tvOS Live TV screen. Browse, List/Guide and Multi-View live
    /// in a header above the content; categories are presented by the shared
    /// Liquid Glass sidebar instead of consuming a permanent leading rail.
    struct TVLiveTVScreen: View {
        let displayedSection: LiveTVSection?
        @Binding var layoutModeRaw: String
        let onOpenBrowse: (String?) -> Void
        let onPlay: (LiveStream) -> Void
        /// Plays a programme from catch-up — a guide cell, or a list row's
        /// "Watch from Start".
        let onPlayCatchup: (LiveStream, EPGSlot) -> Void
        /// Raises Multi-View (or the paywall) from the header.
        let onOpenMultiView: () -> Void
        /// Raises Multi-View seeded with a channel, from its long-press menu.
        let onStartMultiView: (LiveStream) -> Void

        /// The active playlist's id prefix, needed to scope the virtual
        /// (favorites / recently watched) collections in-memory.
        let playlistPrefix: String

        /// The active playlist's source, forwarded so an empty channel list can
        /// explain itself. See `LiveTVEmptyState`.
        let sourceType: PlaylistSourceType?

        private var layoutMode: LiveTVLayoutMode {
            LiveTVLayoutMode.resolved(layoutModeRaw)
        }

        let contentFocusRequest: TVContentFocusRequest?
        let onDidClaimFocus: (TVContentFocusRequest) -> Void

        var body: some View {
            VStack(spacing: 0) {
                TVLiveTVControlsRow(
                    sectionTitle: displayedSection?.titleText ?? Text("Browse Categories"),
                    layoutModeRaw: $layoutModeRaw,
                    onOpenBrowse: { onOpenBrowse(nil) },
                    onOpenMultiView: onOpenMultiView
                )
                content
                BrowseCategoriesButton(onOpen: { onOpenBrowse(nil) })
            }
        }

        @ViewBuilder
        private var content: some View {
            if let section = displayedSection {
                switch layoutMode {
                case .guide:
                    EPGGuideView(
                        scope: section.scope,
                        playlistPrefix: playlistPrefix,
                        onPlay: onPlay,
                        onPlayCatchup: { onPlayCatchup($0, EPGSlot($1)) },
                        onStartMultiView: onStartMultiView,
                        focusRequest: contentFocusRequest,
                        onDidClaimFocus: onDidClaimFocus,
                        onLeadingLeft: { onOpenBrowse(nil) }
                    )
                    .id("\(section.id)-guide")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .list:
                    TVChannelsList(
                        scope: section.scope,
                        playlistPrefix: playlistPrefix,
                        onLeadingLeft: onOpenBrowse,
                        sourceType: sourceType,
                        onStartMultiView: onStartMultiView,
                        onWatchFromStart: onPlayCatchup,
                        onPlay: onPlay,
                        focusRequest: contentFocusRequest,
                        onDidClaimFocus: onDidClaimFocus
                    )
                    .id("\(section.id)-list")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView(
                    "Select a Category",
                    systemImage: "tablecells",
                    description: Text("Choose a category from the list")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - tvOS content controls

    /// A single focus section above Live TV content. Categories open the browse
    /// panel; presentation choices stay visible without living inside it.
    private struct TVLiveTVControlsRow: View {
        let sectionTitle: Text
        @Binding var layoutModeRaw: String
        let onOpenBrowse: () -> Void
        let onOpenMultiView: () -> Void

        private enum Item: Hashable {
            case browse
            case mode(String)
            case multiView
        }

        @FocusState private var focused: Item?

        private var layoutMode: LiveTVLayoutMode {
            LiveTVLayoutMode.resolved(layoutModeRaw)
        }

        var body: some View {
            HStack(spacing: 14) {
                browseButton
                viewModeSwitch
                multiViewButton
                Spacer(minLength: 0)
            }
            .padding(.horizontal, TVLayoutMetrics.contentInset)
            .padding(.top, 30)
            .padding(.bottom, 16)
            .focusSection()
        }

        private var browseButton: some View {
            let isItemFocused = focused == .browse
            return Button(action: onOpenBrowse) {
                HStack(spacing: 12) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 22, weight: .semibold))
                    sectionTitle
                        .font(.system(size: 22, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(minWidth: 280, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 17)
                .foregroundStyle(isItemFocused ? .black : .white)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isItemFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.08)))
                )
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.04))
            .focused($focused, equals: .browse)
            .onLeadingEdgeLeft(onOpenBrowse)
            .accessibilityLabel("Browse Categories")
            .animation(.easeOut(duration: 0.18), value: isItemFocused)
        }

        private var viewModeSwitch: some View {
            HStack(spacing: 6) {
                ForEach(LiveTVLayoutMode.allCases) { mode in
                    modeSegment(mode)
                }
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.08))
            )
        }

        private func modeSegment(_ mode: LiveTVLayoutMode) -> some View {
            let isActive = layoutMode == mode
            let isItemFocused = focused == .mode(mode.rawValue)
            return Button {
                layoutModeRaw = mode.rawValue
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: 20, weight: .semibold))
                    Text(mode.label)
                        .font(.system(size: 18, weight: .semibold))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .foregroundStyle(segmentForeground(isFocused: isItemFocused, isActive: isActive))
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(segmentFill(isFocused: isItemFocused, isActive: isActive))
                )
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.04))
            .focused($focused, equals: .mode(mode.rawValue))
            .accessibilityAddTraits(isActive ? [.isSelected] : [])
            .animation(.easeOut(duration: 0.18), value: isItemFocused)
        }

        private var multiViewButton: some View {
            let isItemFocused = focused == .multiView
            return Button(action: onOpenMultiView) {
                Image(systemName: "rectangle.split.2x2")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 52)
                    .padding(.vertical, 17)
                    .foregroundStyle(isItemFocused ? .black : .white.opacity(0.7))
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isItemFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.08)))
                    )
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.04))
            .focused($focused, equals: .multiView)
            .accessibilityLabel("Multi-View")
            .animation(.easeOut(duration: 0.18), value: isItemFocused)
        }

        private func segmentForeground(isFocused: Bool, isActive: Bool) -> Color {
            if isFocused { return .black }
            if isActive { return .white }
            return .white.opacity(0.5)
        }

        private func segmentFill(isFocused: Bool, isActive: Bool) -> AnyShapeStyle {
            if isFocused { return AnyShapeStyle(.white) }
            if isActive { return AnyShapeStyle(.white.opacity(0.22)) }
            return AnyShapeStyle(.clear)
        }
    }
#endif
