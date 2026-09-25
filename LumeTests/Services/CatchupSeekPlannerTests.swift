//
//  CatchupSeekPlannerTests.swift
//  LumeTests
//
//  Pins how a seek on a catch-up programme becomes the segment the player
//  opens (`CatchupSeekPlanner`), and how a segment's playhead maps onto the
//  programme clock (`CatchupTimeline` / the `PlayableMedia` helpers). The
//  host in `FullScreenPlayerView+Catchup` only applies these answers.
//

import Foundation
@testable import Lume
import Testing

struct CatchupSeekPlannerTests {
    /// Minute-aligned, like real EPG starts, so programme time and wall-clock
    /// minutes line up.
    private let start = Date(timeIntervalSince1970: 1_699_999_980)
    private var end: Date {
        start.addingTimeInterval(3600)
    }

    /// Long after the programme finished, so only its length limits a seek.
    private var afterwards: Date {
        end.addingTimeInterval(3600)
    }

    private func timeline(segmentOffset: TimeInterval = 0) -> CatchupTimeline {
        CatchupTimeline(
            streamID: "l-1",
            programmeTitle: "News",
            programmeStart: start,
            programmeEnd: end,
            segmentStart: start.addingTimeInterval(segmentOffset)
        )
    }

    private func plan(
        _ seek: CatchupSeek,
        current: TimeInterval,
        pending: TimeInterval? = nil,
        segmentOffset: TimeInterval = 0,
        now: Date? = nil
    ) -> TimeInterval? {
        CatchupSeekPlanner.plan(
            seek,
            current: current,
            pendingTarget: pending,
            timeline: timeline(segmentOffset: segmentOffset),
            now: now ?? afterwards
        )
    }

    // MARK: - Rounding to drop-in minutes

    @Test func `offsets floor to the minute`() {
        #expect(CatchupSeekPlanner.floorToStep(0) == 0)
        #expect(CatchupSeekPlanner.floorToStep(59.9) == 0)
        #expect(CatchupSeekPlanner.floorToStep(60) == 60)
        #expect(CatchupSeekPlanner.floorToStep(125) == 120)
        #expect(CatchupSeekPlanner.floorToStep(-30) == 0)
        #expect(CatchupSeekPlanner.floorToStep(.nan) == 0)
    }

    @Test func `a forward skip lands on the drop-in minute after the target`() {
        // 45:30 + 1:00 = 46:30 → opens at 46:00, still ahead of 45:30.
        #expect(plan(.by(60), current: 2730) == 2760)
    }

    @Test func `a forward request never lands inside the minute already playing`() {
        // 10:10 + 0:15 floors back to 10:00, the segment playing — bumped on.
        #expect(plan(.by(15), current: 610, segmentOffset: 600) == 660)
        // Scrubbing forward inside the current minute moves to the next one.
        #expect(plan(.to(2750), current: 2730) == 2760)
    }

    @Test func `a backward request inside the current minute restarts it`() {
        #expect(plan(.to(610), current: 630, segmentOffset: 600) == 600)
        #expect(plan(.by(-20), current: 630, segmentOffset: 600) == 600)
    }

    @Test func `a backward skip floors to its minute`() {
        // 45:30 − 1:00 = 44:30 → 44:00.
        #expect(plan(.by(-60), current: 2730) == 2640)
    }

    @Test func `restart seeks to the programme start`() {
        #expect(plan(.to(0), current: 1234, segmentOffset: 1200) == 0)
    }

    // MARK: - Clamping

    @Test func `a seek before the programme start clamps to zero`() {
        #expect(plan(.by(-60), current: 20) == 0)
        #expect(plan(.to(-10), current: 300) == 0)
    }

    @Test func `a finished programme can start no later than its last minute`() {
        #expect(CatchupSeekPlanner.latestStartableOffset(for: timeline(), now: afterwards) == 3540)
        #expect(plan(.by(600), current: 3500) == 3540)
        #expect(plan(.to(10000), current: 100) == 3540)
    }

    @Test func `an airing programme can start no later than a minute behind now`() {
        // 10:30 into the programme: the newest startable minute is 09:00.
        let now = start.addingTimeInterval(630)
        #expect(CatchupSeekPlanner.latestStartableOffset(for: timeline(), now: now) == 540)
        #expect(plan(.by(300), current: 400, now: now) == 540)
        #expect(plan(.to(3000), current: 100, now: now) == 540)
    }

    @Test func `a programme that only just started can only start at zero`() {
        let now = start.addingTimeInterval(30)
        #expect(CatchupSeekPlanner.latestStartableOffset(for: timeline(), now: now) == 0)
    }

    @Test func `a forward press with nowhere left to go is dropped`() {
        let now = start.addingTimeInterval(630)
        #expect(plan(.by(60), current: 545, segmentOffset: 540, now: now) == nil)
        #expect(plan(.by(60), current: 3590, segmentOffset: 3540) == nil)
    }

    // MARK: - Accumulation

    @Test func `rapid presses accumulate from the pending target`() {
        // The first press chose 11:00; the screen still shows 10:10.
        #expect(plan(.by(60), current: 610, pending: 660, segmentOffset: 600) == 720)
        #expect(plan(.by(-60), current: 610, pending: 660, segmentOffset: 600) == 600)
        #expect(plan(.by(-120), current: 610, pending: 660, segmentOffset: 600) == 540)
    }

    // MARK: - Timeline mapping

    @Test func `a segment maps its playhead onto the programme`() {
        let segment = timeline(segmentOffset: 600)
        #expect(segment.offset == 600)
        #expect(segment.duration == 3600)
        #expect(segment.timelinePosition(12) == 612)
        #expect(segment.timelinePosition(5000) == 3600)
        #expect(segment.enginePosition(612) == 12)
        #expect(segment.enginePosition(500) == 0)
    }

    @Test func `the programme timeline starts on the minute the programme starts in`() {
        let unaligned = CatchupTimeline(
            streamID: "l-1",
            programmeTitle: "News",
            programmeStart: start.addingTimeInterval(20),
            programmeEnd: end,
            segmentStart: start.addingTimeInterval(120)
        )
        #expect(unaligned.origin == start)
        #expect(unaligned.offset == 120)
        #expect(unaligned.duration == 3600)
    }

    @Test func `same programme is judged by channel and schedule, not segment`() {
        #expect(timeline(segmentOffset: 0).isSameProgramme(as: timeline(segmentOffset: 600)))
        let other = CatchupTimeline(
            streamID: "l-2", programmeTitle: "News",
            programmeStart: start, programmeEnd: end, segmentStart: start
        )
        #expect(!timeline().isSameProgramme(as: other))
        #expect(!timeline().isSameProgramme(as: nil))
    }

    // MARK: - PlayableMedia helpers

    private func media(catchup: CatchupTimeline?, id: String = "m") throws -> PlayableMedia {
        try PlayableMedia(
            id: id,
            url: #require(URL(string: "http://example.com/\(id).ts")),
            title: "Channel",
            subtitle: nil,
            posterURL: nil,
            kind: .vod,
            startTime: 0,
            contentRef: .live("l-1"),
            catchup: catchup
        )
    }

    @Test func `catch-up media reports programme time, other media is unchanged`() throws {
        let segment = try media(catchup: timeline(segmentOffset: 600))
        #expect(segment.timelinePosition(30) == 630)
        #expect(segment.timelineDuration(3000) == 3600)
        #expect(segment.enginePosition(630) == 30)

        let movie = try media(catchup: nil)
        #expect(movie.timelinePosition(30) == 30)
        #expect(movie.timelineDuration(3000) == 3000)
        #expect(movie.enginePosition(630) == 630)
    }

    @Test func `catch-up skips a minute, everything else keeps its step`() throws {
        #expect(try media(catchup: timeline()).skipInterval(default: 15) == 60)
        #expect(try media(catchup: timeline()).skipInterval(default: 10) == 60)
        #expect(try media(catchup: nil).skipInterval(default: 15) == 15)
        #expect(try media(catchup: nil).skipInterval(default: 10) == 10)
    }

    @Test func `segments of one programme share a playback session`() throws {
        let first = try media(catchup: timeline(), id: "catchup-a")
        let later = try media(catchup: timeline(segmentOffset: 600), id: "catchup-b")
        #expect(first.playbackSessionID == later.playbackSessionID)
        #expect(try media(catchup: nil, id: "movie-1").playbackSessionID == "movie-1")
    }

    @Test func `skip step symbols and labels follow the interval`() {
        let minute = PlayerSkipStep(seconds: 60)
        #expect(minute.backSymbol == "gobackward.60")
        #expect(minute.forwardSymbol == "goforward.60")
        let standard = PlayerSkipStep(seconds: 15)
        #expect(standard.backSymbol == "gobackward.15")
        #expect(standard.forwardSymbol == "goforward.15")
        #expect(PlayerSkipStep(seconds: 10).backSymbol == "gobackward.10")
    }
}
