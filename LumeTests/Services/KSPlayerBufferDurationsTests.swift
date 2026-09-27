//
//  KSPlayerBufferDurationsTests.swift
//  LumeTests
//
//  Pins the per-stream KSPlayer buffer mapping: catch-up streams get a capped
//  read-ahead, and every other stream keeps the user's settings untouched.
//

import Foundation
@testable import Lume
import Testing

@Suite("KSPlayerBufferDurations")
struct KSPlayerBufferDurationsTests {
    private let cap = TimeInterval(PlayerSettings.KSPlayer.catchupMaxBuffer)

    @Test
    func `the catch-up cap is ten seconds`() {
        #expect(PlayerSettings.KSPlayer.catchupMaxBuffer == 10)
    }

    @Test
    func `live and on-demand streams keep the settings unchanged`() {
        let live = KSPlayerBufferDurations.resolve(liveBuffer: 4, vodBuffer: 8, maxBuffer: 30, isLive: true, isCatchup: false)
        #expect(live == KSPlayerBufferDurations(preferredForward: 4, maximum: 30))

        let vod = KSPlayerBufferDurations.resolve(liveBuffer: 4, vodBuffer: 8, maxBuffer: 30, isLive: false, isCatchup: false)
        #expect(vod == KSPlayerBufferDurations(preferredForward: 8, maximum: 30))

        // Even a forward buffer above the maximum is left as the user set it.
        let odd = KSPlayerBufferDurations.resolve(liveBuffer: 4, vodBuffer: 60, maxBuffer: 30, isLive: false, isCatchup: false)
        #expect(odd == KSPlayerBufferDurations(preferredForward: 60, maximum: 30))
    }

    @Test
    func `catch-up caps the maximum buffer`() {
        let durations = KSPlayerBufferDurations.resolve(liveBuffer: 4, vodBuffer: 8, maxBuffer: 30, isLive: true, isCatchup: true)
        #expect(durations == KSPlayerBufferDurations(preferredForward: 4, maximum: cap))
    }

    @Test
    func `catch-up keeps a maximum already below the cap`() {
        let durations = KSPlayerBufferDurations.resolve(liveBuffer: 4, vodBuffer: 8, maxBuffer: 5, isLive: true, isCatchup: true)
        #expect(durations == KSPlayerBufferDurations(preferredForward: 4, maximum: 5))
    }

    @Test
    func `catch-up clamps the forward buffer to the capped maximum`() {
        let live = KSPlayerBufferDurations.resolve(liveBuffer: 20, vodBuffer: 8, maxBuffer: 30, isLive: true, isCatchup: true)
        #expect(live == KSPlayerBufferDurations(preferredForward: cap, maximum: cap))

        let vod = KSPlayerBufferDurations.resolve(liveBuffer: 4, vodBuffer: 16, maxBuffer: 30, isLive: false, isCatchup: true)
        #expect(vod == KSPlayerBufferDurations(preferredForward: cap, maximum: cap))

        let belowCap = KSPlayerBufferDurations.resolve(liveBuffer: 8, vodBuffer: 8, maxBuffer: 5, isLive: true, isCatchup: true)
        #expect(belowCap == KSPlayerBufferDurations(preferredForward: 5, maximum: 5))
    }
}
