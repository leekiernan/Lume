//
//  LiveChannelHistory.swift
//  Lume
//
//  Tracks the "recall" pair of live channels — the one playing now and the one
//  watched immediately before it — so the player can jump straight back to the
//  last channel, the way a TV remote's recall/last button does. Persisted in
//  `UserDefaults` so recall survives closing and reopening the player, and kept
//  as pure data resolution (no view state) so it can be unit-tested.
//
//  Recently watched channels are *not* a second list here: every surface — Live
//  TV's Recently Watched, Home, and the tvOS in-player "Recent" rail — reads
//  `LiveStream.lastWatchedDate`, and every removal goes through
//  `removeFromRecents` / `clearRecents` below, so the lists can't disagree.
//

import Foundation
import SwiftData

enum LiveChannelHistory {
    private static let currentKeyBase = "player.live.currentChannelId"
    private static let previousKeyBase = "player.live.previousChannelId"
    /// The in-player rail's former private recents list. No longer written or
    /// read (the rail derives from `lastWatchedDate`); still purged with a
    /// profile so an upgraded install doesn't keep it around forever.
    private static let legacyRecentsKeyBase = "player.live.recentChannelIds"

    /// How many channels the in-player "Recent" rail shows. Capped so the rail
    /// stays a quick shortcut rather than a full history.
    private static let recentsRailLimit = 12

    /// Per-profile key. The recall pair is part of a profile's live-TV view
    /// history, so each profile gets its own namespace. The default profile
    /// keeps the original un-suffixed keys, so an upgrading user's existing
    /// recall pair carries over (matching how legacy `UserContentState` records
    /// are claimed by the default profile during bootstrap).
    private static func key(_ base: String, _ profileID: UUID?) -> String {
        guard let profileID, profileID != UserProfile.defaultProfileID else { return base }
        return "\(base).\(profileID.uuidString)"
    }

    /// Note that `media` is now the live channel on screen. The previously
    /// current channel slides into the "previous" slot so it can be recalled.
    /// Non-live media is ignored, so a detour through a movie never clobbers
    /// the recall pair.
    static func record(
        _ media: PlayableMedia,
        profileID: UUID? = ActiveProfileStore.current,
        defaults: UserDefaults = .standard
    ) {
        guard case let .live(id) = media.contentRef else { return }

        let currentKey = key(currentKeyBase, profileID)
        let previousKey = key(previousKeyBase, profileID)

        // Re-selecting the channel already current leaves the recall pair alone.
        let current = defaults.string(forKey: currentKey)
        guard current != id else { return }
        if let current {
            defaults.set(current, forKey: previousKey)
        }
        defaults.set(id, forKey: currentKey)
    }

    // MARK: - Recently watched

    /// The in-player "Recent" rail: the playing channel first, then the same
    /// Recently Watched list Live TV shows for its playlist — the composition
    /// `LiveChannelQuery` gives that list (newest `recentLimit` first, then
    /// scoped to the playlist and the restriction) — capped for the rail.
    ///
    /// `restriction` is required, like `LiveChannelQuery.scoped`'s: this rail is
    /// a channel list the viewer can tune from, so a channel watched *before*
    /// its category was locked must not stay one tab away for a child
    /// mid-playback. The playing channel leads even before its first watch
    /// stamp lands (`WatchProgressWriter` writes it off-main, after the first
    /// progress sample).
    static func recentChannels(
        current: LiveStream,
        in context: ModelContext,
        restriction: ContentRestriction
    ) -> [LiveStream] {
        guard let playlist = LiveChannelNavigator.playlist(for: current, in: context) else { return [current] }
        let descriptor = LiveChannelQuery.descriptor(for: .recentlyWatched, sort: .playlist)
        let recents = LiveChannelQuery.scoped(
            (try? context.fetch(descriptor)) ?? [],
            scope: .recentlyWatched,
            playlistPrefix: "\(playlist.id.uuidString)-",
            restriction: restriction
        )
        let others = recents.lazy.filter { $0.id != current.id }.prefix(recentsRailLimit - 1)
        return [current] + others
    }

    /// Removes one channel from Recently Watched on every surface, and from
    /// the recall slot if it is the channel recall would jump back to — a
    /// channel the viewer just asked to forget shouldn't come back on the next
    /// recall press.
    static func removeFromRecents(
        _ stream: LiveStream,
        in context: ModelContext,
        profileID: UUID? = ActiveProfileStore.current,
        defaults: UserDefaults = .standard
    ) {
        stream.lastWatchedDate = nil
        try? context.save()
        let previousKey = key(previousKeyBase, profileID)
        if defaults.string(forKey: previousKey) == stream.id {
            defaults.removeObject(forKey: previousKey)
        }
    }

    /// Clears the watch stamp on every recently watched channel — all of them,
    /// or only one playlist's when `playlistPrefix` is given — saving every
    /// `batchSize` rows. The shared body of Live TV's "Clear" and the storage
    /// screen's watch-history wipe; runs on the caller's (background) context.
    nonisolated static func clearRecents(
        in context: ModelContext,
        playlistPrefix: String? = nil,
        batchSize: Int
    ) throws {
        let channels = try context.fetch(FetchDescriptor<LiveStream>(
            predicate: #Predicate { $0.lastWatchedDate != nil }
        ))
        var cleared = 0
        for channel in channels where playlistPrefix.map({ channel.id.hasPrefix($0) }) ?? true {
            channel.lastWatchedDate = nil
            cleared += 1
            if cleared.isMultiple(of: batchSize) { try context.save() }
        }
        try context.save()
    }

    /// Forgets the recall pair, for a full watch-history wipe.
    static func clearRecall(
        profileID: UUID? = ActiveProfileStore.current,
        defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: key(currentKeyBase, profileID))
        defaults.removeObject(forKey: key(previousKeyBase, profileID))
    }

    /// The channel to jump back to — the live stream watched immediately before
    /// the current one — resolved into a `PlayableMedia`. `nil` when no prior
    /// channel has been recorded or it can no longer be resolved (e.g. removed
    /// in a sync). `scope` is the list playback is currently surfing; it carries
    /// over so recall doesn't drop the viewer out of it (the navigator falls
    /// back to the channel's category when the recalled channel isn't in it).
    ///
    /// `restriction` is required rather than defaulted, like `LiveChannelQuery`'s
    /// and `LiveChannelNavigator.adjacentMedia`'s: recall is a channel the viewer
    /// can tune to with one remote press, and the pair is recorded before a
    /// category is hidden or locked — so a channel watched *before* the lock
    /// would otherwise stay one press away for a child mid-playback. Hidden
    /// channels drop out for the same reason every other channel query filters
    /// them.
    static func recallMedia(
        in context: ModelContext,
        scope: LiveChannelScope? = nil,
        restriction: ContentRestriction,
        profileID: UUID? = ActiveProfileStore.current,
        defaults: UserDefaults = .standard
    ) -> PlayableMedia? {
        guard let previousId = defaults.string(forKey: key(previousKeyBase, profileID)) else { return nil }
        var descriptor = FetchDescriptor<LiveStream>(
            predicate: #Predicate { $0.id == previousId && $0.isHidden == false }
        )
        descriptor.fetchLimit = 1
        guard let stream = try? context.fetch(descriptor).first,
              !restriction.hides(categoryID: stream.categoryId),
              let playlist = LiveChannelNavigator.playlist(for: stream, in: context) else { return nil }
        return PlayableMedia.from(stream: stream, playlist: playlist, scope: scope)
    }

    /// Drop a profile's live-TV view history. Called when a profile is deleted so
    /// its recall pair (and any legacy recents list) doesn't linger in
    /// `UserDefaults`. The default profile's un-suffixed keys are never purged
    /// this way.
    static func purge(profileID: UUID, defaults: UserDefaults = .standard) {
        guard profileID != UserProfile.defaultProfileID else { return }
        defaults.removeObject(forKey: key(currentKeyBase, profileID))
        defaults.removeObject(forKey: key(previousKeyBase, profileID))
        defaults.removeObject(forKey: key(legacyRecentsKeyBase, profileID))
    }
}
