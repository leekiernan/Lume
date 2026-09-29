//
//  IntentMerge.swift
//  Lume
//
//  The three-way merge for synced state that the viewer can clear — per-title
//  state (watched, progress, favourites, hidden, order, votes) and parental
//  category restrictions — read from what each side actually knows rather
//  than from nil.
//
//  The generic merge (`CloudSyncMerge.reconcile`) reads a missing value as a
//  deletion. For this state that was wrong both ways:
//  - a missing cloud record — not imported yet, lost, deduped — cleared it on
//    this device;
//  - a catalog row that came back blank — deleted and re-inserted by a
//    playlist resync — read as the viewer clearing it, and the cloud record
//    was deleted on every device. For a restriction, that lifted it.
//  Both are the same guess: absence taken for a decision. Here a clear is
//  explicit on each side instead. The viewer's clears are recorded on this
//  device (`ContentClearLedger`), and a clear reaches the cloud as a record in
//  its cleared form — never as a deletion — so an absent record only ever
//  means "don't know yet".
//
//  Pure: the engine reads each side, asks for a verdict, and applies it.
//

import Foundation

/// State the viewer can clear, synced as a record either way.
nonisolated protocol IntentMergeValue: Equatable {
    /// What a clear writes.
    static var cleared: Self { get }
    var isCleared: Bool { get }
    /// Both sides changed since they last agreed.
    static func mergeConflict(local: Self, cloud: Self) -> Self
}

/// What this device knows.
nonisolated enum LocalReading<Value: IntentMergeValue>: Equatable {
    /// The catalog row carries state.
    case state(Value)
    /// The row is in its cleared form because the viewer cleared it here.
    case clearedByUser
    /// The row is in its cleared form with no record of the viewer clearing
    /// it — reset or re-created by a catalog sync. Says nothing about what the
    /// viewer wants.
    case blank
    /// No catalog row on this device (not synced yet, or pruned).
    case missingRow
}

/// What the cloud knows.
nonisolated enum CloudReading<Value: IntentMergeValue>: Equatable {
    /// A record — one in its cleared form is a clear someone made.
    case state(Value)
    /// No record: never synced, not imported to this device yet, or lost.
    case absent
}

nonisolated enum IntentVerdict<Value: IntentMergeValue>: Equatable {
    case noChange
    /// Write the cloud record (in its cleared form: the clear) and adopt as
    /// the shadow.
    case pushToCloud(Value)
    /// Write the catalog row and adopt as the shadow.
    case pullToLocal(Value)
    /// Both sides changed: write the merged value to both.
    case writeBoth(Value)
    /// The cloud has something for a row this device doesn't have yet. The
    /// shadow stays, so it lands when the row does.
    case pending
}

nonisolated enum IntentMerge {
    static func reconcile<Value: IntentMergeValue>(
        local: LocalReading<Value>,
        cloud: CloudReading<Value>,
        shadow: Value?
    ) -> IntentVerdict<Value> {
        let cloudValue: Value? = if case let .state(value) = cloud { value } else { nil }
        switch local {
        case .missingRow:
            // Nothing can be written here; a change waits for the row. A clear
            // needs nothing — a row that returns starts cleared.
            guard let cloudValue, cloudValue != shadow, !cloudValue.isCleared else { return .noChange }
            return .pending
        case .blank:
            // Not the viewer's doing: whatever the cloud holds is still true.
            guard let cloudValue else { return .noChange }
            if cloudValue.isCleared, shadow == cloudValue { return .noChange }
            return .pullToLocal(cloudValue)
        case .clearedByUser:
            return merge(local: .cleared, cloud: cloudValue, shadow: shadow)
        case let .state(value):
            return merge(local: value, cloud: cloudValue, shadow: shadow)
        }
    }

    /// Local is known. An absent cloud record is unknown, not a deletion: the
    /// local value is pushed back — re-creating a lost record — unless there's
    /// nothing to say (a clear of something never synced).
    private static func merge<Value: IntentMergeValue>(
        local: Value,
        cloud: Value?,
        shadow: Value?
    ) -> IntentVerdict<Value> {
        guard let cloud else {
            if local.isCleared, shadow == nil || shadow == local { return .noChange }
            return .pushToCloud(local)
        }
        switch CloudSyncMerge.reconcile(
            local: local, cloud: cloud, shadow: shadow,
            mergeConflict: Value.mergeConflict
        ) {
        case .noChange: return .noChange
        case let .pushToCloud(value): return value.map(IntentVerdict.pushToCloud) ?? .noChange
        case let .pullToLocal(value): return value.map(IntentVerdict.pullToLocal) ?? .noChange
        case let .writeBoth(value): return .writeBoth(value)
        }
    }

    /// How long a cleared record is kept. It has to outlast every device's
    /// next sync — one that missed it would read its absence as "don't know"
    /// and write its old state back — but cleared records mustn't pile up for
    /// ever either.
    static let clearedRecordLifetime: TimeInterval = 90 * 24 * 60 * 60

    static func clearedRecordExpired(updatedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(updatedAt) > clearedRecordLifetime
    }
}

// MARK: - Per-title state

typealias LocalContentReading = LocalReading<ContentStateValues>
typealias CloudContentReading = CloudReading<ContentStateValues>
typealias ContentIntentVerdict = IntentVerdict<ContentStateValues>

nonisolated enum ContentIntentMerge {
    static func reconcile(
        local: LocalContentReading,
        cloud: CloudContentReading,
        shadow: ContentStateValues?
    ) -> ContentIntentVerdict {
        IntentMerge.reconcile(local: local, cloud: cloud, shadow: shadow)
    }
}

nonisolated extension ContentStateValues: IntentMergeValue {
    /// No user state: what a clear writes.
    static let empty = ContentStateValues(
        watchProgress: 0, isWatched: false, lastWatchedDate: nil,
        isFavorite: false, addedToWatchlistDate: nil, favoriteOrder: nil
    )

    static var cleared: ContentStateValues {
        empty
    }

    var isCleared: Bool {
        isEmpty
    }
}

// MARK: - Category restrictions

typealias LocalRestrictionReading = LocalReading<CategoryRestrictionValues>
typealias CloudRestrictionReading = CloudReading<CategoryRestrictionValues>

nonisolated extension CategoryRestrictionValues: IntentMergeValue {
    /// A lifted restriction.
    static var cleared: CategoryRestrictionValues {
        CategoryRestrictionValues(isRestricted: false)
    }

    var isCleared: Bool {
        !isRestricted
    }
}
