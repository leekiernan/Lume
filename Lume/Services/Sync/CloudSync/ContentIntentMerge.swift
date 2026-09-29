//
//  ContentIntentMerge.swift
//  Lume
//
//  The three-way merge for per-title user state (watched, progress,
//  favourites, hidden, order, votes), read from what each side actually knows
//  rather than from nil.
//
//  The generic merge (`CloudSyncMerge.reconcile`) reads a missing value as a
//  deletion. For content that was wrong both ways:
//  - a missing cloud record — not imported yet, lost, deduped — cleared the
//    title on this device;
//  - a catalog row that came back blank — deleted and re-inserted by a
//    playlist resync — read as the viewer unmarking it, and the cloud record
//    was deleted on every device.
//  Both are the same guess: absence taken for a decision. Here a clear is
//  explicit on each side instead. The viewer's clears are recorded on this
//  device (`ContentClearLedger`), and a clear reaches the cloud as a record
//  with every field at its default — never as a deletion — so an absent record
//  only ever means "don't know yet".
//
//  Pure: the engine reads each side, asks for a verdict, and applies it.
//

import Foundation

/// What this device knows about a title's user state.
nonisolated enum LocalContentReading: Equatable {
    /// The catalog row carries user state.
    case state(ContentStateValues)
    /// The row is blank because the viewer cleared it here.
    case clearedByUser
    /// The row is blank with no record of the viewer clearing it — reset or
    /// re-created by a catalog sync. Says nothing about what the viewer wants.
    case blank
    /// No catalog row on this device (not synced yet, or pruned).
    case missingRow
}

/// What the cloud knows about a title's user state.
nonisolated enum CloudContentReading: Equatable {
    /// A record — an all-default one is a clear someone made.
    case state(ContentStateValues)
    /// No record: never synced, not imported to this device yet, or lost.
    case absent
}

nonisolated enum ContentIntentVerdict: Equatable {
    case noChange
    /// Write the cloud record (all-default: the clear) and adopt as the shadow.
    case pushToCloud(ContentStateValues)
    /// Write the catalog row and adopt as the shadow.
    case pullToLocal(ContentStateValues)
    /// Both sides changed: write the merged value to both.
    case writeBoth(ContentStateValues)
    /// The cloud has something for a row this device doesn't have yet. The
    /// shadow stays, so it lands when the row does.
    case pending
}

nonisolated enum ContentIntentMerge {
    static func reconcile(
        local: LocalContentReading,
        cloud: CloudContentReading,
        shadow: ContentStateValues?
    ) -> ContentIntentVerdict {
        let cloudValue: ContentStateValues? = if case let .state(value) = cloud { value } else { nil }
        switch local {
        case .missingRow:
            // Nothing can be written here; a change waits for the row.
            guard let cloudValue, cloudValue != shadow else { return .noChange }
            return .pending
        case .blank:
            // Not the viewer's doing: whatever the cloud holds is still true.
            guard let cloudValue else { return .noChange }
            if cloudValue.isEmpty, shadow == cloudValue { return .noChange }
            return .pullToLocal(cloudValue)
        case .clearedByUser:
            return merge(local: .empty, cloud: cloudValue, shadow: shadow)
        case let .state(value):
            return merge(local: value, cloud: cloudValue, shadow: shadow)
        }
    }

    /// Local is known. An absent cloud record is unknown, not a deletion: the
    /// local value is pushed back — re-creating a lost record — unless there's
    /// nothing to say (a clear of something never synced).
    private static func merge(
        local: ContentStateValues,
        cloud: ContentStateValues?,
        shadow: ContentStateValues?
    ) -> ContentIntentVerdict {
        guard let cloud else {
            if local.isEmpty, shadow == nil || shadow == local { return .noChange }
            return .pushToCloud(local)
        }
        switch CloudSyncMerge.reconcile(
            local: local, cloud: cloud, shadow: shadow,
            mergeConflict: ContentStateValues.mergeConflict
        ) {
        case .noChange: return .noChange
        case let .pushToCloud(value): return value.map(ContentIntentVerdict.pushToCloud) ?? .noChange
        case let .pullToLocal(value): return value.map(ContentIntentVerdict.pullToLocal) ?? .noChange
        case let .writeBoth(value): return .writeBoth(value)
        }
    }
}

nonisolated extension ContentStateValues {
    /// No user state: what a clear writes.
    static let empty = ContentStateValues(
        watchProgress: 0, isWatched: false, lastWatchedDate: nil,
        isFavorite: false, addedToWatchlistDate: nil, favoriteOrder: nil
    )
}
