import Foundation
@testable import Lume
import Testing

@MainActor
struct CatalogMatchSelectionTests {
    private nonisolated struct Item: Identifiable, CategorizedContent {
        let id: String
        let categoryId: String?
    }

    @Test func `restricted preferred match falls back in source order`() {
        let items = [Item(id: "other-1", categoryId: nil), Item(id: "active-1", categoryId: "hidden"),
                     Item(id: "active-2", categoryId: "adult"), Item(id: "other-2", categoryId: nil)]
        let child = ContentRestriction(isActive: true, restrictedCategoryIDs: ["adult"], hiddenCategoryIDs: ["hidden"])
        #expect(CatalogMatchSelection.preferred(in: items, restriction: child, playlistPrefix: "active-")?.id == "other-1")
        let parent = ContentRestriction(hiddenCategoryIDs: ["hidden"])
        #expect(CatalogMatchSelection.preferred(in: items, restriction: parent, playlistPrefix: "active-")?.id == "active-2")
        #expect(CatalogMatchSelection.preferred(in: items, restriction: parent, playlistPrefix: nil)?.id == "other-1")
        #expect(CatalogMatchSelection.preferred(in: [Item](), restriction: child, playlistPrefix: nil) == nil)
    }
}
