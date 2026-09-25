//
//  LiveStream+Catchup.swift
//  Lume
//
//  The one definition of catch-up eligibility. Badges, the guide's replay
//  cells, the tvOS in-player browser and `PlayableMedia.catchup` all ask these
//  helpers, so a channel is never flagged as replayable on one surface and
//  refused on another.
//

import Foundation

/// The archive window arithmetic, on plain values so the guide's off-main
/// snapshots (`EPGChannelRow`) can share it without touching the model.
nonisolated enum CatchupWindow {
    /// The earliest programme start still inside an archive reaching back
    /// `archiveDays` days from `now`.
    static func earliestStart(archiveDays: Int, now: Date) -> Date {
        now.addingTimeInterval(-TimeInterval(max(1, archiveDays)) * 86400)
    }

    /// Whether a programme starting at `start` is still inside the archive.
    static func contains(start: Date, archiveDays: Int, now: Date) -> Bool {
        start >= earliestStart(archiveDays: archiveDays, now: now)
    }
}

extension LiveStream {
    /// Whether the channel can serve catch-up at all: it advertises an archive
    /// and is an Xtream stream (catch-up URLs need credentials, so an m3u
    /// channel with a `directURL` can't be replayed even if it claims one).
    var supportsCatchup: Bool {
        tvArchive > 0 && directURL == nil
    }

    /// How many days the archive reaches back. Providers sometimes advertise an
    /// archive with a zero duration; treat that as one day, as playback does.
    var catchupArchiveDays: Int {
        max(1, tvArchiveDuration)
    }

    /// Whether a programme that started at `start` is replayable at `now`.
    func isCatchupAvailable(start: Date, now: Date) -> Bool {
        supportsCatchup && CatchupWindow.contains(start: start, archiveDays: catchupArchiveDays, now: now)
    }
}
