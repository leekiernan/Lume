@testable import Lume
import Testing

struct BrowseSidebarFocusTests {
    @Test func `remembered row below the fold is restored rather than the top`() {
        let rows = (0 ..< 200).map { "category-\($0)" }
        #expect(BrowseSidebarFocusPolicy.landingID(lastFocusedID: rows[175], availableIDs: rows) == rows[175])
    }

    @Test func `hub and category use the same remembered focus rule`() {
        #expect(BrowseSidebarFocusPolicy.landingID(lastFocusedID: "last", availableIDs: ["first", "last"]) == "last")
        #expect(BrowseSidebarFocusPolicy.landingID(lastFocusedID: nil, availableIDs: ["first", "last"]) == "first")
    }

    @Test func `removed focus targets fall back only to existing rows`() {
        #expect(BrowseSidebarFocusPolicy.landingID(lastFocusedID: "removed", availableIDs: ["first"]) == "first")
        #expect(BrowseSidebarFocusPolicy.landingID(lastFocusedID: "last", availableIDs: []) == nil)
    }

    @Test func `releasing native focus while scrolling to an off-screen row does not dismiss the panel`() {
        var handoff = BrowseSidebarFocusPolicy.Handoff()
        #expect(!handoff.shouldReturnToContent)
        #expect(!handoff.shouldRememberFocus)
        handoff.didFocusRow() // The engine initially chooses the visible top row.
        #expect(!handoff.shouldReturnToContent) // landTVFocus releases it before scrolling.
        #expect(!handoff.shouldRememberFocus) // Don't replace the off-screen remembered row.
        handoff.finishLanding()
        #expect(handoff.shouldReturnToContent) // A subsequent nil focus is a real exit.
        #expect(handoff.shouldRememberFocus)
    }

    @Test func `finishing a landing that never took native focus is not an exit`() {
        var handoff = BrowseSidebarFocusPolicy.Handoff()
        handoff.finishLanding()
        #expect(!handoff.shouldReturnToContent)
        handoff.didFocusRow()
        #expect(handoff.shouldReturnToContent)
    }
}
