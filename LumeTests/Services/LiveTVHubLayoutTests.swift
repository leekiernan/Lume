import Foundation
@testable import Lume
import Testing

struct LiveTVHubLayoutTests {
    @Test func `all live TV rails can be reordered and hidden without losing future rows`() {
        let rows = LiveTVHubLayout.rows(orderRaw: "startingSoon\nus-essentials\nfavorites\nfavorites\nunknown", hiddenRaw: "favorites\nuk-essentials")
        #expect(rows.prefix(2).map(\.id) == ["startingSoon", "us-essentials"])
        #expect(!rows.contains(.favorites))
        #expect(!rows.contains(.unitedKingdom))
        #expect(rows.contains(.canada))
        #expect(rows.contains(.australia))
        #expect(rows.contains(.newZealand))
        #expect(rows.contains(.southAfrica))
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test func `settings include empty countries while the hub keeps default ordering`() {
        #expect(LiveTVHubLayout.rows(orderRaw: "") == LiveTVHubRow.allCases)
        #expect(LiveTVHubLayout.rows(orderRaw: "", hiddenRaw: SectionTokens.encode(LiveTVHubRow.allCases.map(\.id))).isEmpty)
    }
}
