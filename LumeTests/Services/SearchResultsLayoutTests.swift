import Foundation
@testable import Lume
import Testing

@MainActor
struct SearchResultsLayoutTests {
    @Test func `search filter layouts`() {
        #expect(SearchResultsLayout(filter: .all) == .overview)
        #expect(SearchResultsLayout(filter: .movies) == .movies)
        #expect(SearchResultsLayout(filter: .series) == .series)
        #expect(SearchResultsLayout(filter: .liveTV) == .channels)
    }
}
