import Foundation
@testable import Lume
import Testing

@MainActor
struct HeroInfoTransitionTests {
    @Test func `hero ignores superseded fade and reset`() throws {
        let transition = HeroInfoTransition<String>()
        transition.reset(to: "a")
        let second = try #require(transition.beginSelection("b"))
        let third = try #require(transition.beginSelection("c"))
        transition.completeFade(second)
        #expect(transition.displayedID == "a")
        transition.completeFade(third)
        #expect(transition.displayedID == "c")
        let first = try #require(transition.beginSelection("a"))
        transition.reset(to: "replacement")
        transition.completeFade(first)
        #expect(transition.displayedID == "replacement")
        #expect(transition.opacity == 1)
    }

    @Test func `hero return to outgoing slide wins`() throws {
        let transition = HeroInfoTransition<String>()
        transition.reset(to: "a")
        let second = try #require(transition.beginSelection("b"))
        let first = try #require(transition.beginSelection("a"))
        transition.completeFade(second)
        transition.completeFade(first)
        #expect(transition.displayedID == "a")
        #expect(transition.beginSelection("a") == nil)
        let empty = try #require(transition.beginSelection(nil))
        transition.completeFade(empty)
        #expect(transition.displayedID == nil)
    }

    @Test func `removing pending hero invalidates fade without leaving overlay invisible`() throws {
        let transition = HeroInfoTransition<String>()
        transition.reset(to: "a")
        let removed = try #require(transition.beginSelection("b"))
        transition.reconcile(ids: ["a", "c"], selectedID: "c")
        transition.completeFade(removed)
        #expect(transition.displayedID == "c")
        #expect(transition.opacity == 1)
        transition.reconcile(ids: [], selectedID: nil)
        #expect(transition.displayedID == nil)
    }
}
