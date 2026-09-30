//
//  RecentResumePoints.swift
//  Lume
//
//  Where each title was last saved in this run, so reopening it resumes there.
//
//  Progress is written on the writer's own background context
//  (`WatchProgressWriter`) so a save never hitches playback. The Movie or
//  Episode a screen already holds lives in the main context, which doesn't
//  reliably pick up that write before the viewer presses Play again — so the
//  resume point came out one save behind: close at 5:51, reopen at 0:00; close
//  at 1:52, reopen at 5:51.
//
//  The player records each position here as it saves it. A resume point takes
//  whichever is newer — this record, or the model's own `lastWatchedDate` —
//  so progress that arrives later from another device still wins.
//

import Foundation
import Synchronization

/// Read off the main thread too — the player resolves its neighbours'
/// playable media on a context of its own — so the store sits behind a lock.
nonisolated enum RecentResumePoints {
    private struct Saved {
        let position: TimeInterval
        let savedAt: Date
    }

    private static let saved = Mutex<[PlayableMedia.ContentRef: Saved]>([:])

    /// Live channels have no position to resume.
    static func record(_ position: TimeInterval, for ref: PlayableMedia.ContentRef, at now: Date = Date()) {
        if case .live = ref { return }
        saved.withLock { $0[ref] = Saved(position: position, savedAt: now) }
    }

    /// Where `ref` should resume: the position saved here if it's newer than
    /// the model's, otherwise the model's.
    static func position(for ref: PlayableMedia.ContentRef, stored: TimeInterval, storedAt: Date?) -> TimeInterval {
        guard let recent = saved.withLock({ $0[ref] }) else { return stored }
        if let storedAt, storedAt > recent.savedAt { return stored }
        return recent.position
    }

    /// Where `ref` should open: its resume point (`position(for:…)`), or the
    /// start when that point is the end of a finished title. Resuming there
    /// lands in the last seconds, where auto-advance plays the next episode
    /// straight away — pressing Previous Episode bounced back to the one just
    /// left, and a watched movie ended as it opened.
    ///
    /// With a known duration, finished means past the watched line
    /// (`WatchCompletion`). Without one, a watched title starts over unless a
    /// newer save this run says the viewer is partway through a rewatch.
    static func start(
        for ref: PlayableMedia.ContentRef,
        stored: TimeInterval,
        storedAt: Date?,
        isWatched: Bool,
        duration: Int?
    ) -> TimeInterval {
        let resume = position(for: ref, stored: stored, storedAt: storedAt)
        if let duration, duration > 0 {
            return WatchCompletion.isComplete(progress: resume, duration: TimeInterval(duration)) ? 0 : resume
        }
        return isWatched && resume == stored ? 0 : resume
    }
}
