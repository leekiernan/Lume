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
        /// Opens the category sidebar when the viewer presses left from a row.
        let onLeadingLeft: () -> Void
        /// Seeds Multi-View with this channel, gated on Lume Pro by the host.
        let onStartMultiView: (LiveStream) -> Void
        let onPlay: (LiveStream) -> Void
        @Environment(\.modelContext) private var modelContext
        /// Drops channels in categories locked away from a child profile — the
        /// iOS list has always done this; this one didn't, so Favorites and
        /// Recently Watched still surfaced them here.
        @Environment(\.contentRestriction) private var restriction
        @Query private var streams: [LiveStream]
        /// Now/next EPG for the visible channels, resolved in one off-main fetch
        /// (see `ChannelEPGSnapshot`) instead of a per-row `@Query`.
        @State private var epgByChannel: [String: ChannelEPG] = [:]
        /// Observed so the EPG lookup refreshes when a guide import finishes.
        @State private var epgSync = EPGSyncService.shared
        /// How many channels are currently rendered. Grows by a page as the list
        /// nears its end so a large category loads lazily instead of all at once.
        @State private var visibleCount = LiveChannelQuery.pageSize
        /// Drives the "Clear Recently Watched" confirmation alert.
        @State private var confirmingClear = false

        init(
            scope: LiveChannelScope,
            playlistPrefix: String,
            sort: ContentSortOption,
            onLeadingLeft: @escaping () -> Void,
            onStartMultiView: @escaping (LiveStream) -> Void,
            onPlay: @escaping (LiveStream) -> Void
        ) {
            self.scope = scope
            self.playlistPrefix = playlistPrefix
            self.onLeadingLeft = onLeadingLeft
            self.onStartMultiView = onStartMultiView
            self.onPlay = onPlay
            _streams = Query(LiveChannelQuery.descriptor(for: scope, sort: sort))
        }

        private var scopedStreams: [LiveStream] {
            LiveChannelQuery.scoped(streams, scope: scope, playlistPrefix: playlistPrefix, restriction: restriction)
        }

        var body: some View {
            let channels = scopedStreams
            let visible = Array(channels.prefix(visibleCount))
            ScrollView {
                LazyVStack(spacing: 14) {
                    if channels.isEmpty {
                        ContentUnavailableView(
                            "No Channels",
                            systemImage: "antenna.radiowaves.left.and.right",
                            description: Text("This category has no channels")
                        )
                        .padding(.top, 80)
                    } else {
                        if scope == .recentlyWatched {
                            clearButton
                                .onLeadingEdgeLeft(onLeadingLeft)
                        }
                        ForEach(visible) { stream in
                            TVChannelRow(
                                stream: stream,
                                epg: epgByChannel[stream.epgChannelId ?? ""],
                                onRemove: scope == .recentlyWatched ? { removeFromRecentlyWatched(stream) } : nil,
                                onStartMultiView: { onStartMultiView(stream) },
                                onPlay: { onPlay(stream) }
                            )
                            .onLeadingEdgeLeft(onLeadingLeft)
                            .onAppear {
                                if stream.id == visible.last?.id, visibleCount < channels.count {
                                    visibleCount = min(visibleCount + LiveChannelQuery.pageSize, channels.count)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 40)
            }
            .focusSection()
            // Reload when the visible window or channel set changes, or a guide
            // import settles — EPG is resolved only for the channels on screen.
            .task(id: "\(channels.count)-\(visible.count)-\(epgSync.isSyncing)") {
                await loadEPG(for: visible)
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

        private func loadEPG(for channels: [LiveStream]) async {
            let channelIds = Array(Set(channels.compactMap(\.epgChannelId).filter { !$0.isEmpty }))
            guard !channelIds.isEmpty else {
                epgByChannel = [:]
                return
            }
            let container = modelContext.container
            let now = Date()
            epgByChannel = await Task.detached(priority: .userInitiated) {
                ChannelEPGLoader.load(container: container, channelIds: channelIds, now: now)
            }.value
        }

        /// Clears a channel's watch timestamp so it drops out of the Recently
        /// Watched list. The @Query-backed list updates once the change is saved.
        private func removeFromRecentlyWatched(_ stream: LiveStream) {
            stream.lastWatchedDate = nil
            try? modelContext.save()
        }

        /// Empties the whole Recently Watched list for the active playlist. The
        /// section drops away on its own once the last timestamp clears (its
        /// parent gates it on `hasRecents`).
        private func clearRecentlyWatched() {
            let container = modelContext.container
            Task { await StorageManager.clearRecentlyWatchedChannels(playlistPrefix: playlistPrefix, container: container) }
        }
    }

    private struct TVChannelRow: View {
        let stream: LiveStream
        /// The channel's now/next programmes, resolved once by the parent list
        /// (see `ChannelEPGSnapshot`) rather than by a per-row `@Query`.
        var epg: ChannelEPG?
        var onRemove: (() -> Void)?
        var onStartMultiView: (() -> Void)?
        let onPlay: () -> Void

        @Environment(\.modelContext) private var modelContext
        @FocusState private var isFocused: Bool

        private var currentEPG: EPGSlot? {
            epg?.current
        }

        private var nextEPG: EPGSlot? {
            epg?.next
        }

        var body: some View {
            Button(action: onPlay) {
                HStack(spacing: 24) {
                    logo

                    VStack(alignment: .leading, spacing: 6) {
                        Text(stream.name)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(primaryColor)
                            .lineLimit(1)

                        if let current = currentEPG {
                            Text(current.title)
                                .font(.system(size: 25))
                                .foregroundStyle(secondaryColor)
                                .lineLimit(1)

                            HStack(spacing: 6) {
                                Text(current.start, style: .time)
                                Text("–")
                                Text(current.end, style: .time)
                            }
                            .font(.system(size: 22))
                            .foregroundStyle(tertiaryColor)

                            if let next = nextEPG {
                                HStack(spacing: 6) {
                                    Text("Next:")
                                    Text(next.title).lineLimit(1)
                                    Text(next.start, style: .time)
                                }
                                .font(.system(size: 22))
                                .foregroundStyle(tertiaryColor)
                            }
                        } else if stream.epgChannelId != nil {
                            Text("No EPG data")
                                .font(.system(size: 22))
                                .foregroundStyle(tertiaryColor)
                        } else {
                            Text("Live")
                                .font(.system(size: 22))
                                .foregroundStyle(secondaryColor)
                        }

                        if stream.tvArchive > 0 {
                            Label("Catchup: \(stream.tvArchiveDuration)d", systemImage: "clock.arrow.circlepath")
                                .font(.system(size: 22))
                                .foregroundStyle(Color.blue)
                        }
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(tertiaryColor)
                }
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
                onStartMultiView: onStartMultiView,
                onRemoveFromRecents: onRemove
            )
        }

        private var logo: some View {
            CachedAsyncImage(url: URL(string: stream.streamIcon ?? ""), maxPixelSize: 84) { phase in
                switch phase {
                case .empty:
                    Rectangle().fill(Color.white.opacity(0.12)).overlay { ProgressView() }
                case let .success(image):
                    image.resizable().aspectRatio(contentMode: .fit)
                case .failure:
                    Rectangle().fill(Color.white.opacity(0.12))
                        .overlay {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(secondaryColor)
                        }
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 84, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }

        private var primaryColor: Color {
            .white
        }

        private var secondaryColor: Color {
            .white.opacity(0.7)
        }

        private var tertiaryColor: Color {
            .white.opacity(0.45)
        }
    }

    // MARK: - tvOS Live TV screen

    /// The unified tvOS Live TV screen. Browse, List/Guide and Multi-View live
    /// in a header above the content; categories are presented by the shared
    /// Liquid Glass sidebar instead of consuming a permanent leading rail.
    struct TVLiveTVScreen: View {
        let displayedSection: LiveTVSection?
        @Binding var layoutModeRaw: String
        let contentSort: ContentSortOption
        let onOpenBrowse: () -> Void
        let onPlay: (LiveStream) -> Void
        let onPlayCatchup: (LiveStream, EPGProgramCell) -> Void
        /// Raises Multi-View (or the paywall) from the header.
        let onOpenMultiView: () -> Void
        /// Raises Multi-View seeded with a channel, from its long-press menu.
        let onStartMultiView: (LiveStream) -> Void

        /// The active playlist's id prefix, needed to scope the virtual
        /// (favorites / recently watched) collections in-memory.
        let playlistPrefix: String

        private var layoutMode: LiveTVLayoutMode {
            LiveTVLayoutMode(rawValue: layoutModeRaw) ?? .list
        }

        /// Bumped when the user selects a sidebar category, asking the guide to
        /// take focus on the first channel. Reset once the guide claims it.
        @Binding var guideFocusToken: Int

        var body: some View {
            VStack(spacing: 0) {
                TVLiveTVControlsRow(
                    sectionTitle: displayedSection?.titleText ?? Text("Browse Categories"),
                    layoutModeRaw: $layoutModeRaw,
                    onOpenBrowse: onOpenBrowse,
                    onOpenMultiView: onOpenMultiView
                )
                content
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
                        sort: contentSort,
                        onPlay: onPlay,
                        onPlayCatchup: onPlayCatchup,
                        onStartMultiView: onStartMultiView,
                        focusToken: guideFocusToken,
                        onDidClaimFocus: { guideFocusToken = 0 },
                        onLeadingLeft: onOpenBrowse
                    )
                    .id("\(section.id)-\(contentSort.rawValue)-guide")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .list:
                    TVChannelsList(
                        scope: section.scope,
                        playlistPrefix: playlistPrefix,
                        sort: contentSort,
                        onLeadingLeft: onOpenBrowse,
                        onStartMultiView: onStartMultiView,
                        onPlay: onPlay
                    )
                    .id("\(section.id)-\(contentSort.rawValue)-list")
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
            LiveTVLayoutMode(rawValue: layoutModeRaw) ?? .list
        }

        var body: some View {
            HStack(spacing: 14) {
                browseButton
                viewModeSwitch
                multiViewButton
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 60)
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
