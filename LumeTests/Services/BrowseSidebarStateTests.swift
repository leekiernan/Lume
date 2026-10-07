@testable import Lume
import Testing

@MainActor
struct BrowseSidebarStateTests {
    @Test func `activation remembers and dismisses before navigating exactly once`() {
        let state = BrowseSidebarState()
        state.isPresented = true
        var visits = 0
        state.activate(rowID: "category") {
            visits += 1
            #expect(state.rememberedRowID == "category")
            #expect(!state.isPresented)
        }
        #expect(visits == 1)
    }

    @Test func `closing without navigation preserves the remembered off-screen row`() {
        let state = BrowseSidebarState()
        state.rememberedRowID = "category-175"
        state.isPresented = true
        state.isPresented = false
        state.isPresented = true
        let ids = (0 ..< 200).map { "category-\($0)" }
        #expect(BrowseSidebarFocusPolicy.landingID(lastFocusedID: state.rememberedRowID, availableIDs: ids) == "category-175")
    }

    @Test func `all areas use the same activation owner without sharing each others position`() {
        let areas = ["movies", "series", "live", "sports"]
        let states = areas.map { _ in BrowseSidebarState() }
        for (index, state) in states.enumerated() {
            state.isPresented = true
            state.activate(rowID: areas[index]) {}
        }
        #expect(states.map(\.rememberedRowID) == areas.map(Optional.some))
        #expect(states.allSatisfy { !$0.isPresented })
        states[0].rememberedRowID = "another-movie-category"
        #expect(states[1].rememberedRowID == "series")
    }

    @Test func `a secondary action uses the same dismissal path as category navigation`() {
        let state = BrowseSidebarState()
        state.isPresented = true
        var showingManagement = false
        state.activate(rowID: "manage") {
            #expect(!state.isPresented)
            showingManagement = true
        }
        #expect(showingManagement)
        #expect(state.rememberedRowID == "manage")
    }
}
