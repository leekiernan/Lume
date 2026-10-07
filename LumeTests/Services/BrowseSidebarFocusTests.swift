@testable import Lume
import Testing

struct BrowseSidebarFocusTests {
    @Test func `active selection below the fold wins over an incidental remembered row`() {
        let rows = (0 ..< 200).map { "category-\($0)" }
        #expect(BrowseSidebarFocusPolicy.landingID(selectedID: rows[175], lastFocusedID: rows[0], availableIDs: rows) == rows[175])
    }

    @Test func `unselected hub preserves focus memory without inventing a selection`() {
        #expect(BrowseSidebarFocusPolicy.landingID(selectedID: nil, lastFocusedID: "last", availableIDs: ["first", "last"]) == "last")
        #expect(BrowseSidebarFocusPolicy.landingID(selectedID: nil, lastFocusedID: nil, availableIDs: ["first", "last"]) == "first")
    }

    @Test func `removed selections and focus targets fall back only to existing rows`() {
        #expect(BrowseSidebarFocusPolicy.landingID(selectedID: "removed", lastFocusedID: "last", availableIDs: ["first", "last"]) == "last")
        #expect(BrowseSidebarFocusPolicy.landingID(selectedID: "removed", lastFocusedID: "removed", availableIDs: ["first"]) == "first")
        #expect(BrowseSidebarFocusPolicy.landingID(selectedID: "removed", lastFocusedID: "last", availableIDs: []) == nil)
    }

    @Test func `releasing native focus while scrolling to an off-screen row does not dismiss the panel`() {
        var handoff = BrowseSidebarFocusPolicy.Handoff()
        #expect(!handoff.shouldReturnToContent)
        handoff.didFocusRow() // The engine initially chooses the visible top row.
        #expect(!handoff.shouldReturnToContent) // landTVFocus releases it before scrolling.
        handoff.finishLanding()
        #expect(handoff.shouldReturnToContent) // A subsequent nil focus is a real exit.
    }

    @Test func `finishing a landing that never took native focus is not an exit`() {
        var handoff = BrowseSidebarFocusPolicy.Handoff()
        handoff.finishLanding()
        #expect(!handoff.shouldReturnToContent)
        handoff.didFocusRow()
        #expect(handoff.shouldReturnToContent)
    }
}
