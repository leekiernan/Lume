import Foundation
@testable import Lume
import Testing

struct SectionTokensTests {
    @Test func `saved order drops unknown duplicates and appends new sections`() {
        #expect(SectionTokens.ordered("soon\nunknown\nfavorites\nsoon", available: ["recents", "favorites", "soon", "new-country"])
            == ["soon", "favorites", "recents", "new-country"])
        #expect(SectionTokens.ordered("", available: ["recents", "favorites"]) == ["recents", "favorites"])
    }

    @Test func `hidden sections toggle with stable encoding`() {
        let hidden = SectionTokens.toggling("us", in: "uk\nuk")
        #expect(hidden == "uk\nus")
        #expect(SectionTokens.toggling("uk", in: hidden) == "us")
    }
}
