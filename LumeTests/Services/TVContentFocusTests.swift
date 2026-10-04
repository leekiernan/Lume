import Foundation
@testable import Lume
import Testing

struct TVContentFocusTests {
    private let scope = TVContentFocusRequest.Scope(playlistPrefix: "p-", channelScope: .favorites, visibilityToken: "parent")

    @Test func `a stale or replayed completion cannot clear a newer handoff`() throws {
        var machine = TVContentFocusMachine()
        machine.requestFocus(in: scope)
        let first = try #require(machine.request)
        machine.requestFocus(in: scope, channelID: "second")
        let second = try #require(machine.request)
        let stale = machine.didClaim(first)
        #expect(!stale)
        #expect(machine.request == second)
        let claimed = machine.didClaim(second)
        #expect(claimed)
        #expect(machine.request == nil)
        let replayed = machine.didClaim(second)
        #expect(!replayed)
    }

    @Test func `cancellation and a recreated owner reject the abandoned request`() throws {
        var original = TVContentFocusMachine()
        original.requestFocus(in: scope)
        let old = try #require(original.request)
        original.cancel()
        let cancelled = original.didClaim(old)
        #expect(!cancelled)
        var replacement = TVContentFocusMachine()
        replacement.requestFocus(in: scope)
        let recreated = replacement.didClaim(old)
        #expect(!recreated)
        #expect(replacement.request != nil)
    }

    @Test func `landing expands a lazy window to include the remembered channel`() throws {
        let ids = (0 ..< 250).map { "channel-\($0)" }
        let request = TVContentFocusRequest(scope: scope, channelID: ids[225])
        let landing = try #require(request.landing(in: scope, channelIDs: ids))
        #expect(landing.channelID == ids[225])
        #expect(landing.minimumVisibleCount == 226)
        #expect(landing.requestID == request.id)
        #expect(request.landing(in: scope, channelIDs: []) == nil)
        let removed = try #require(request.landing(in: scope, channelIDs: ["remaining"]))
        #expect(removed.channelID == "remaining")
        #expect(removed.minimumVisibleCount == 1)
    }

    @Test func `playlist section and visibility scope cannot leak a focus target`() {
        let request = TVContentFocusRequest(scope: scope, channelID: "channel")
        for other in [
            TVContentFocusRequest.Scope(playlistPrefix: "other-", channelScope: .favorites, visibilityToken: "parent"),
            TVContentFocusRequest.Scope(playlistPrefix: "p-", channelScope: .recentlyWatched, visibilityToken: "parent"),
            TVContentFocusRequest.Scope(playlistPrefix: "p-", channelScope: .favorites, visibilityToken: "child")
        ] {
            #expect(request.landing(in: other, channelIDs: ["channel"]) == nil)
        }
    }
}

@MainActor
struct TVFocusLandingTests {
    @Test func `release and scroll precede settled focus assertion`() async {
        var events: [String] = []
        let claimed = await TVFocusLanding.perform(release: { events.append("release") }, scroll: {
            events.append("scroll")
        }, assert: { events.append("assert") }, settle: { events.append("settle") })
        #expect(claimed)
        #expect(events == ["release", "scroll", "settle", "assert"])
    }

    @Test func `dismissal before or during settlement never asserts focus`() async {
        var presented = false
        var released = false
        var asserted = false
        let absent = await TVFocusLanding.perform(release: { released = true }, assert: {
            asserted = true
        }, while: { presented }, settle: {})
        #expect(!absent && !released && !asserted)
        presented = true
        let dismissed = await TVFocusLanding.perform(release: { released = true }, assert: {
            asserted = true
        }, while: { presented }, settle: { presented = false })
        #expect(!dismissed && released && !asserted)
    }

    @Test func `a cancellation-resistant sleeper cannot revive departed focus`() async {
        var asserted = false
        let task = Task {
            await TVFocusLanding.perform(release: {}, assert: { asserted = true }, settle: {
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        let claimed = await task.value
        #expect(!claimed)
        #expect(!asserted)
    }

    @Test func `settlement failure is not a successful claim`() async {
        var asserted = false
        let claimed = await TVFocusLanding.perform(release: {}, assert: { asserted = true }, settle: {
            throw CancellationError()
        })
        #expect(!claimed && !asserted)
    }
}
