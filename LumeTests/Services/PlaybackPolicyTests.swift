//
//  PlaybackPolicyTests.swift
//  LumeTests
//
//  The one policy every engine plays by.
//

@testable import Lume
import Testing

struct PlaybackPolicyTests {
    @Test func `a start error retries only on the last engine`() {
        #expect(PlaybackPolicy.retriesStartupError(canFallBack: false))
        #expect(!PlaybackPolicy.retriesStartupError(canFallBack: true))
    }

    @Test func `the quick window applies only while another engine is left`() {
        #expect(PlaybackPolicy.startupTimeout(quick: true) == 15)
        #expect(PlaybackPolicy.startupTimeout(quick: false) == 40)
        #expect(PlaybackPolicy.startupTimeout(quick: true) < PlaybackPolicy.liveStallTimeout)
    }

    @Test func `tile windows remain shorter without changing full screen deadlines`() {
        #expect(PlaybackPolicy.tileStartupTimeout(quick: true) == 12)
        #expect(PlaybackPolicy.tileStartupTimeout(quick: false) == 25)
        for quick in [false, true] {
            #expect(PlaybackPolicy.tileStartupTimeout(quick: quick) < PlaybackPolicy.startupTimeout(quick: quick))
        }
        #expect(PlaybackPolicy.startupTimeout(quick: true) == 15)
        #expect(PlaybackPolicy.startupTimeout(quick: false) == 40)
    }
}
