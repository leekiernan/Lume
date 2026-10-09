//
//  ChannelsListView.swift
//  Lume
//
//  The iOS / macOS Live TV channel list: a paged, lazily-mounted list of the
//  channels in the selected section, each card carrying the now/next EPG the
//  list resolves for its visible window (see `ChannelEPGSnapshot`). Split out of
//  `LiveTVView` for the same reason `LiveTVTVComponents` holds the tvOS list —
//  to keep that file focused on cross-platform composition, and inside the
//  project's file-length cap.
//

import SwiftData
import SwiftUI

struct ChannelsList: View {
    let scope: LiveChannelScope
    let playlistPrefix: String
    /// Seeds Multi-View with this channel, gated on Lume Pro by the host.
    let onStartMultiView: (LiveStream) -> Void
    /// Replays the programme on air from its start, via catch-up.
    let onWatchFromStart: (LiveStream, EPGSlot) -> Void
    let onPlay: (LiveStream) -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    @Query private var streams: [LiveStream]
    /// Now/next EPG for the visible channels, resolved in one off-main fetch
    /// (see `ChannelEPGSnapshot`) instead of a per-card `@Query`.
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

    init(
        scope: LiveChannelScope,
        playlistPrefix: String,
        onStartMultiView: @escaping (LiveStream) -> Void,
        onWatchFromStart: @escaping (LiveStream, EPGSlot) -> Void,
        onPlay: @escaping (LiveStream) -> Void
    ) {
        self.scope = scope
        self.playlistPrefix = playlistPrefix
        self.onStartMultiView = onStartMultiView
        self.onWatchFromStart = onWatchFromStart
        self.onPlay = onPlay
        _streams = Query(LiveChannelQuery.descriptor(for: scope, sort: .playlist))
    }

    private var scopedStreams: [LiveStream] {
        LiveChannelQuery.scoped(streams, scope: scope, playlistPrefix: playlistPrefix, restriction: restriction)
    }

    /// Clears a channel's watch timestamp so it drops out of the Recently
    /// Watched list. The @Query-backed list updates once the change is saved.
    private func removeFromRecentlyWatched(_ stream: LiveStream) {
        LiveChannelHistory.removeFromRecents(stream, in: modelContext)
    }

    /// Empties the whole Recently Watched list for the active playlist. The
    /// section drops away on its own once the last timestamp clears (its parent
    /// gates it on `hasRecents`).
    private func clearRecentlyWatched() {
        let container = modelContext.container
        Task { await StorageManager.clearRecentlyWatchedChannels(playlistPrefix: playlistPrefix, container: container) }
    }

    /// A trailing "Clear" button shown above the Recently Watched list. Stays
    /// out of the scroll view so it's always reachable no matter how far the
    /// list is scrolled.
    private var clearHeader: some View {
        HStack {
            Spacer()
            Button(role: .destructive) {
                confirmingClear = true
            } label: {
                Label("Clear", systemImage: "trash")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    var body: some View {
        let channels = scopedStreams
        let visible = Array(channels.prefix(visibleCount))
        let epgScope = ChannelEPGLoadMachine.Scope(
            playlistPrefix: playlistPrefix, visibilityToken: restriction.visibilityToken, channelScope: scope
        )
        let epgKey = ChannelEPGLoadMachine.Key(
            scope: epgScope,
            refresh: .init(channelIDs: Set(channels.compactMap(\.epgChannelId)), revision: epgSync.readRevision, minute: epgSync.clockMinute),
            visibleChannelIDs: Set(visible.compactMap(\.epgChannelId))
        )
        let epgByChannel = epgLoad.snapshot(for: epgScope)
        VStack(spacing: 0) {
            if scope == .recentlyWatched, !channels.isEmpty {
                clearHeader
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    if channels.isEmpty {
                        ContentUnavailableView(
                            "No Channels",
                            systemImage: "antenna.radiowaves.left.and.right",
                            description: Text("This category has no channels")
                        )
                    } else {
                        ForEach(visible) { stream in
                            let epg = epgByChannel[stream.epgChannelId ?? ""]
                            Button {
                                onPlay(stream)
                            } label: {
                                LiveStreamCardView(
                                    stream: stream, epg: epg,
                                    categoryName: stream.categoryId.flatMap { categoryNames[$0] }
                                )
                                .padding(.horizontal)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .liveChannelMenu(
                                isFavorite: stream.isFavorite,
                                onToggleFavorite: { LiveChannelFavorites.toggle(stream, in: modelContext) },
                                onWatchFromStart: LiveChannelRestart.action(for: stream, current: epg?.current) {
                                    onWatchFromStart(stream, $0)
                                },
                                onStartMultiView: { onStartMultiView(stream) },
                                onRemoveFromRecents: scope == .recentlyWatched ? { removeFromRecentlyWatched(stream) } : nil
                            )
                            .onAppear {
                                if stream.id == visible.last?.id, visibleCount < channels.count {
                                    visibleCount = min(visibleCount + LiveChannelQuery.pageSize, channels.count)
                                }
                            }

                            Divider()
                                .padding(.leading, 88)
                        }
                    }
                }
            }
            .browseActivity()
            // Reload when the visible window or channel set changes, or a guide
            // import settles — EPG is resolved only for the channels on screen.
            .task(id: epgKey) {
                await ChannelEPGLoading.run(key: epgKey, machine: $epgLoad, container: modelContext.container)
            }
            .task(id: Set(channels.compactMap(\.categoryId))) {
                guard scope.showsCategoryLabels else { return }
                categoryNames = LiveCategoryNames.names(for: channels, in: modelContext)
            }
        }
        .alert("Clear Recently Watched", isPresented: $confirmingClear) {
            Button("Clear", role: .destructive) { clearRecentlyWatched() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the list of channels you've recently watched. Your favorites and the channels themselves aren't affected.")
        }
    }
}
