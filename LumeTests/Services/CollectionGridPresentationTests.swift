@testable import Lume
import Testing

@MainActor
struct CollectionGridPresentationTests {
    @Test func `an unprepared or loading grid does not claim to be empty`() throws {
        var pagination = PaginationMachine()
        #expect(presentation(pagination) == .loading)
        pagination.prepare(for: "category")
        let pending = pagination.beginLoading()
        let request = try #require(pending)
        #expect(presentation(pagination) == .loading)
        pagination.finish(request, scanned: 0, hasMore: false)
        #expect(presentation(pagination) == .empty)
    }

    @Test func `import and split resolution use loading instead of an overlapping empty state`() {
        #expect(CollectionGridPresentation.resolve(hasItems: false, isLoading: true) == .loading)
        #expect(CollectionGridPresentation.resolve(hasItems: false, isLoading: false) == .empty)
    }

    @Test func `refreshes and subsequent pages never replace existing cards with a spinner`() {
        #expect(CollectionGridPresentation.resolve(hasItems: true, isLoading: true) == .content)
        #expect(CollectionGridPresentation.resolve(hasItems: true, isLoading: false) == .content)
    }

    @Test func `a failed first page exits loading instead of spinning indefinitely`() throws {
        var pagination = PaginationMachine()
        pagination.prepare(for: "category")
        let pending = pagination.beginLoading()
        let request = try #require(pending)
        pagination.abandon(request)
        #expect(presentation(pagination) == .empty)
    }

    private func presentation(_ pagination: PaginationMachine) -> CollectionGridPresentation {
        .resolve(hasItems: false, isLoading: pagination.key != "category" || pagination.isLoading)
    }
}
