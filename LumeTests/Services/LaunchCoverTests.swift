//
//  LaunchCoverTests.swift
//  LumeTests
//
//  The launch splash lifts once Home has something to show — its hero, or a
//  settled decision without one — or another tab opened, or it waited long
//  enough.
//

@testable import Lume
import Testing

@MainActor
struct LaunchCoverTests {
    @Test func `it stays while the hero is loading`() {
        var cover = LaunchCover()
        let whileLoading = cover.handle(.homeShowed(.content(hero: .loading), feedSettled: false))
        #expect(!whileLoading)
        #expect(cover.isCovering)
        let withHero = cover.handle(.homeShowed(.content(hero: .content), feedSettled: false))
        #expect(withHero)
        #expect(cover.state == .revealed(.homeReady))
    }

    /// Home's first frame reads `disabled` before the hero is seeded — the
    /// launch log shows it — so that alone mustn't lift the splash.
    @Test func `a disabled hero counts only once the feeds settle`() {
        var cover = LaunchCover()
        let firstFrame = cover.handle(.homeShowed(.content(hero: .disabled), feedSettled: false))
        #expect(!firstFrame)
        let settled = cover.handle(.homeShowed(.content(hero: .disabled), feedSettled: true))
        #expect(settled)
    }

    @Test func `settled without a hero is ready`() {
        #expect(LaunchCover.homeIsReady(.content(hero: .empty), feedSettled: false))
        #expect(LaunchCover.homeIsReady(.content(hero: .failed), feedSettled: false))
        #expect(LaunchCover.homeIsReady(.empty, feedSettled: true))
        #expect(LaunchCover.homeIsReady(.noPlaylists, feedSettled: false))
    }

    @Test func `another tab or the timeout lifts it, once`() {
        var other = LaunchCover()
        let byTab = other.handle(.otherTabShown)
        #expect(byTab)
        #expect(other.state == .revealed(.homeNotShown))
        let lateTimeout = other.handle(.timedOut)
        #expect(!lateTimeout)

        var late = LaunchCover()
        let byTimeout = late.handle(.timedOut)
        #expect(byTimeout)
        #expect(late.state == .revealed(.timedOut))
    }
}
