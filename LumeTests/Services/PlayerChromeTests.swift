//
//  PlayerChromeTests.swift
//  LumeTests
//
//  When every engine draws its controls.
//

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
}
