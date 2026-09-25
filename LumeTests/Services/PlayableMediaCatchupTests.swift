//
//  PlayableMediaCatchupTests.swift
//  LumeTests
//
//  `PlayableMedia.catchup` as the player's seek path uses it: every catch-up
//  seek opens a new segment of the programme, built here. Kept apart from
//  `PlayableMediaTests`, which is at the type-length cap.
//

import Foundation
@testable import Lume
import Testing

struct PlayableMediaCatchupTests {
    private func makePlaylist() -> Playlist {
        Playlist(name: "Test", serverURL: "http://example.com:8080", username: "user", password: "pass")
    }

    @Test func `catchup opening segment starts at the programme`() throws {
        let playlist = makePlaylist()
        playlist.serverTimezone = "UTC"
        let stream = LiveStream(id: "l-3c", streamId: 300, name: "Archive Channel", tvArchive: 1, tvArchiveDuration: 7)
        // 2023-11-14 22:13:20 UTC — deliberately not on a minute boundary.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3600)

        let media = try #require(PlayableMedia.catchup(
            stream: stream, playlist: playlist, programTitle: "Evening News", start: start, end: end
        ))
        let timeline = try #require(media.catchup)
        #expect(timeline.streamID == "l-3c")
        #expect(timeline.programmeTitle == "Evening News")
        #expect(timeline.programmeStart == start)
        #expect(timeline.programmeEnd == end)
        #expect(timeline.offset == 0)
        #expect(media.url.absoluteString.hasSuffix("/timeshift/user/pass/60/2023-11-14:22-13/300.ts"))
    }

    @Test func `catchup segment URL starts at the segment and runs to the programme end`() throws {
        let playlist = makePlaylist()
        playlist.serverTimezone = "UTC"
        let stream = LiveStream(id: "l-3d", streamId: 300, name: "Archive Channel", tvArchive: 1, tvArchiveDuration: 7)
        let start = Date(timeIntervalSince1970: 1_700_000_000) // 22:13:20 UTC
        let end = start.addingTimeInterval(3600) // 23:13:20 UTC

        // Ten minutes into the programme timeline, which starts at 22:13:00.
        let segmentStart = CatchupTimeline.minuteFloor(start).addingTimeInterval(600)
        let media = try #require(PlayableMedia.catchup(
            stream: stream, playlist: playlist, programTitle: "Evening News",
            start: start, end: end, segmentStart: segmentStart
        ))
        // 22:23 → 23:13:20 is 50⅓ minutes, rounded up.
        #expect(media.url.absoluteString.hasSuffix("/timeshift/user/pass/51/2023-11-14:22-23/300.ts"))
        #expect(media.catchup?.offset == 600)
        #expect(media.catchup?.duration == 3620)
        #expect(media.kind == .vod)
        #expect(media.contentRef == .live("l-3d"))
        #expect(media.startTime == 0)
    }

    @Test func `catchup segment start is floored and kept inside the programme`() throws {
        let playlist = makePlaylist()
        let stream = LiveStream(id: "l-3e", streamId: 300, name: "Archive Channel", tvArchive: 1, tvArchiveDuration: 7)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3600)

        let midMinute = try #require(PlayableMedia.catchup(
            stream: stream, playlist: playlist, programTitle: "x",
            start: start, end: end, segmentStart: start.addingTimeInterval(630)
        ))
        #expect(midMinute.catchup?.offset == 600)

        let beforeStart = try #require(PlayableMedia.catchup(
            stream: stream, playlist: playlist, programTitle: "x",
            start: start, end: end, segmentStart: start.addingTimeInterval(-3600)
        ))
        #expect(beforeStart.catchup?.offset == 0)

        let afterEnd = try #require(PlayableMedia.catchup(
            stream: stream, playlist: playlist, programTitle: "x",
            start: start, end: end, segmentStart: end.addingTimeInterval(600)
        ))
        // The last whole minute before the end: 23:12:00, 59 minutes in.
        #expect(afterEnd.catchup?.offset == 3540)
        #expect(afterEnd.url.absoluteString.contains("/timeshift/user/pass/2/"))
    }

    @Test func `each catchup segment has its own id but one playback session`() throws {
        let playlist = makePlaylist()
        let stream = LiveStream(id: "l-3f", streamId: 300, name: "Archive Channel", tvArchive: 1, tvArchiveDuration: 7)
        let start = Date(timeIntervalSince1970: 1_699_999_980)
        let end = start.addingTimeInterval(3600)

        let first = try #require(PlayableMedia.catchup(
            stream: stream, playlist: playlist, programTitle: "x", start: start, end: end
        ))
        let later = try #require(PlayableMedia.catchup(
            stream: stream, playlist: playlist, programTitle: "x",
            start: start, end: end, segmentStart: start.addingTimeInterval(600)
        ))
        let sameAgain = try #require(PlayableMedia.catchup(
            stream: stream, playlist: playlist, programTitle: "x",
            start: start, end: end, segmentStart: start.addingTimeInterval(630)
        ))
        #expect(first.id != later.id)
        #expect(later.id == sameAgain.id)
        #expect(first.playbackSessionID == later.playbackSessionID)
        #expect(first.catchup?.isSameProgramme(as: later.catchup) == true)
    }

    @Test @MainActor func `copies keep the catchup timeline`() throws {
        let playlist = makePlaylist()
        let stream = LiveStream(id: "l-3g", streamId: 300, name: "Archive Channel", tvArchive: 1, tvArchiveDuration: 7)
        let start = Date(timeIntervalSince1970: 1_699_999_980)
        let media = try #require(PlayableMedia.catchup(
            stream: stream, playlist: playlist, programTitle: "x",
            start: start, end: start.addingTimeInterval(3600), segmentStart: start.addingTimeInterval(600)
        ))
        #expect(media.resuming(at: 42).catchup == media.catchup)
        #expect(try media.replacingURL(#require(URL(string: "http://example.com/other.ts"))).catchup == media.catchup)

        let decoded = try JSONDecoder().decode(PlayableMedia.self, from: JSONEncoder().encode(media))
        #expect(decoded == media)
    }
}
