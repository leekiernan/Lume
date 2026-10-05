//
//  LiveChannelMenu.swift
//  Lume
//
//  The secondary actions on a live channel row — long-press on iOS and tvOS,
//  right-click on macOS. One menu rather than several stacked modifiers: only
//  the outermost `contextMenu` survives on a view, so every action a channel
//  offers has to be built here.
//

import SwiftData
import SwiftUI

extension View {
    /// - Parameters:
    ///   - isFavorite: drives the favorite item's wording and glyph.
    ///   - onWatchFromStart: restarts the programme on air from its beginning;
    ///     nil hides the item (see `LiveChannelRestart.action`).
    ///   - onStartMultiView: omitted where Multi-View has no entry point.
    ///   - onRemoveFromRecents: only in the Recently Watched collection.
    func liveChannelMenu(
        isFavorite: Bool,
        onToggleFavorite: @escaping () -> Void,
        onWatchFromStart: (() -> Void)? = nil,
        onStartMultiView: (() -> Void)? = nil,
        onRemoveFromRecents: (() -> Void)? = nil
    ) -> some View {
        contextMenu {
            if let onWatchFromStart {
                LiveChannelMenuItems.watchFromStart(onWatchFromStart)
            }

            FavoriteMenuItems.favorite(isFavorite: isFavorite, action: onToggleFavorite)

            if let onStartMultiView {
                LiveChannelMenuItems.startMultiView(onStartMultiView)
            }

            if let onRemoveFromRecents {
                FavoriteMenuItems.removeFromRecents(onRemoveFromRecents)
            }
        }
    }
}

enum LiveChannelMenuItems {
    static func watchFromStart(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label("Watch from Start", systemImage: "play.fill") }
    }

    static func startMultiView(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Start Multi-View", systemImage: "rectangle.split.2x2")
        }
    }
}

/// The items `liveChannelMenu` and `mediaFavoriteMenu` both offer. The two menus
/// are twins by design, so their shared wording and glyphs live in one place —
/// a rename that only lands in one of them would create a fresh untranslated key
/// (see `MediaFavoriteMenuStringsTests`).
enum FavoriteMenuItems {
    static func favorite(isFavorite: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(
                isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: isFavorite ? "heart.slash" : "heart"
            )
        }
    }

    static func removeFromRecents(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Label("Remove from Recently Watched", systemImage: "clock.badge.xmark")
        }
    }
}

/// Builds a channel row's "Watch from Start" action from the now/next snapshot
/// it already shows. Eligibility is `LiveStream.restartableProgramme` — asked
/// when the row renders, to decide whether the item appears, and again when it
/// is chosen, because a menu can stay open past the programme's end or the
/// snapshot can go stale under it: then the action does nothing.
enum LiveChannelRestart {
    static func action(
        for stream: LiveStream,
        current: EPGSlot?,
        now: Date = .now,
        perform: @escaping (EPGSlot) -> Void
    ) -> (() -> Void)? {
        guard stream.restartableProgramme(current, now: now) != nil else { return nil }
        return {
            guard let programme = stream.restartableProgramme(current, now: .now) else { return }
            perform(programme)
        }
    }
}

/// Flips a channel's favorite flag. Live streams toggle the flag alone — unlike
/// movies and series, which also stamp `addedToWatchlistDate` — mirroring
/// `PlayerFavorites` and the detail screens.
enum LiveChannelFavorites {
    @discardableResult
    static func toggle(_ stream: LiveStream, in context: ModelContext) -> Bool {
        stream.isFavorite.toggle()
        if !stream.isFavorite { ContentClearLedger.shared.record(stream.id) }
        try? context.save()
        return stream.isFavorite
    }
}
