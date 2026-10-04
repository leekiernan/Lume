//
//  PlayerChromeTests.swift
//  LumeTests
//
//  When every engine draws its controls.
//

import Foundation
@testable import Lume
import Testing

@MainActor
struct PlayerChromeTests {
    @Test func `controls wait for the first frame`() {
        #expect(!PlayerChrome.drawsControls(requested: true, started: false, failed: false))
        #expect(PlayerChrome.drawsControls(requested: true, started: true, failed: false))
    }

    @Test func `a loading catch-up segment keeps its scrubber`() {
        #expect(PlayerChrome.drawsControls(requested: true, started: false, catchupSegmentLoading: true, failed: false))
    }

    @Test func `nothing draws unless asked for, or over a failure`() {
        #expect(!PlayerChrome.drawsControls(requested: false, started: true, failed: false))
        #expect(!PlayerChrome.drawsControls(requested: true, started: true, failed: true))
    }

    @Test func `same programme seeks retain controls including consecutive loading segments`() {
        let previous = timeline()
        let next = timeline(segmentOffset: 600)
        #expect(PlayerChrome.keepsCatchupControls(previous: previous, next: next, started: true, alreadyLoading: false))
        #expect(PlayerChrome.keepsCatchupControls(previous: previous, next: next, started: false, alreadyLoading: true))
        #expect(!PlayerChrome.keepsCatchupControls(previous: previous, next: next, started: false, alreadyLoading: false))
    }

    @Test func `another channel programme or non catchup stream must wait for a first frame`() {
        let previous = timeline()
        for next in [nil, timeline(streamID: "other"), timeline(programmeOffset: 3600)] {
            #expect(!PlayerChrome.keepsCatchupControls(previous: previous, next: next, started: true, alreadyLoading: true))
        }
        #expect(!PlayerChrome.keepsCatchupControls(previous: nil, next: previous, started: true, alreadyLoading: true))
    }

    @Test func `catchup presentation does not override hidden controls or a terminal failure`() {
        #expect(!PlayerChrome.drawsControls(requested: false, started: false, catchupSegmentLoading: true, failed: false))
        #expect(!PlayerChrome.drawsControls(requested: true, started: false, catchupSegmentLoading: true, failed: true))
    }

    private func timeline(streamID: String = "channel", programmeOffset: TimeInterval = 0, segmentOffset: TimeInterval = 0) -> CatchupTimeline {
        let start = Date(timeIntervalSince1970: 1_700_000_000 + programmeOffset)
        return CatchupTimeline(
            streamID: streamID, programmeTitle: "Programme", programmeStart: start,
            programmeEnd: start.addingTimeInterval(3600), segmentStart: start.addingTimeInterval(segmentOffset)
        )
    }
}
