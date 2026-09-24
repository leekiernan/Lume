import Foundation
@testable import Lume
import Testing

struct CustomHomeSectionTests {
    private static let popular = CustomHomeSection(
        title: "Popular Movies",
        sourceURL: "https://mdblist.com/lists/official/movies/popular"
    )

    // MARK: - Store

    @Test func `encode then decode round trip`() {
        let sections = [Self.popular, CustomHomeSection(title: "Shows", sourceURL: "https://mdblist.com/lists/official/shows/popular")]
        let decoded = CustomHomeSections.decode(CustomHomeSections.encode(sections))
        #expect(decoded == sections)
    }

    @Test func `decode empty storage`() {
        #expect(CustomHomeSections.decode("").isEmpty)
    }

    @Test func `decode garbage storage yields nothing rather than crashing`() {
        #expect(CustomHomeSections.decode("{not json").isEmpty)
    }

    @Test func `encode empty list stores nothing`() {
        #expect(CustomHomeSections.encode([]).isEmpty)
    }

    @Test func `upsert appends a new section`() {
        let result = CustomHomeSections.upsert(Self.popular, into: [])
        #expect(result == [Self.popular])
    }

    @Test func `upsert replaces in place by id`() {
        var edited = Self.popular
        edited.title = "Renamed"
        let result = CustomHomeSections.upsert(edited, into: [Self.popular])
        #expect(result.count == 1)
        #expect(result.first?.title == "Renamed")
        #expect(result.first?.id == Self.popular.id)
    }

    @Test func `upsert refuses to grow past the cap`() {
        let existing = (0 ..< CustomHomeSections.maximumCount).map {
            CustomHomeSection(title: "List \($0)", sourceURL: "https://mdblist.com/lists/u/l\($0)")
        }
        let result = CustomHomeSections.upsert(Self.popular, into: existing)
        #expect(result.count == CustomHomeSections.maximumCount)
        #expect(!result.contains(Self.popular))
    }

    /// Editing a full list must still work — the cap only blocks *new* rows.
    @Test func `upsert still edits when the list is full`() {
        var existing = (0 ..< CustomHomeSections.maximumCount).map {
            CustomHomeSection(title: "List \($0)", sourceURL: "https://mdblist.com/lists/u/l\($0)")
        }
        existing[3].title = "Before"
        var edited = existing[3]
        edited.title = "After"
        let result = CustomHomeSections.upsert(edited, into: existing)
        #expect(result.count == CustomHomeSections.maximumCount)
        #expect(result[3].title == "After")
    }

    @Test func `remove drops only the named section`() {
        let other = CustomHomeSection(title: "Other", sourceURL: "https://mdblist.com/lists/u/other")
        let result = CustomHomeSections.remove(id: Self.popular.id, from: [Self.popular, other])
        #expect(result == [other])
    }

    // MARK: - Content signature

    @Test func `content signature ignores a rename`() {
        var renamed = Self.popular
        renamed.title = "Different Header"
        #expect(
            CustomHomeSections.contentSignature([Self.popular])
                == CustomHomeSections.contentSignature([renamed])
        )
    }

    @Test func `content signature changes when the URL changes`() {
        var repointed = Self.popular
        repointed.sourceURL = "https://mdblist.com/lists/official/shows/popular"
        #expect(
            CustomHomeSections.contentSignature([Self.popular])
                != CustomHomeSections.contentSignature([repointed])
        )
    }

    @Test func `content signature changes when a section is added`() {
        let extra = CustomHomeSection(title: "Extra", sourceURL: "https://mdblist.com/lists/u/extra")
        #expect(
            CustomHomeSections.contentSignature([Self.popular])
                != CustomHomeSections.contentSignature([Self.popular, extra])
        )
    }

    // MARK: - Account signature

    private static let traktList = CustomHomeSection(title: "Mine", sourceURL: "https://trakt.tv/users/me/lists/mine")

    /// Connecting Trakt can't change what an MDBList row shows, so it mustn't
    /// refetch one.
    @Test func `account signature ignores the account when no row reads from Trakt`() {
        #expect(CustomHomeSections.accountSignature([Self.popular], traktUsername: "alice") == "")
        #expect(CustomHomeSections.accountSignature([Self.popular], traktUsername: nil) == "")
    }

    /// A private list's rows must not outlive a disconnect or carry over to
    /// another account.
    @Test func `account signature changes with the Trakt account`() {
        let sections = [Self.popular, Self.traktList]
        let alice = CustomHomeSections.accountSignature(sections, traktUsername: "alice")
        let bob = CustomHomeSections.accountSignature(sections, traktUsername: "bob")
        let disconnected = CustomHomeSections.accountSignature(sections, traktUsername: nil)
        #expect(Set([alice, bob, disconnected]).count == 3)
    }

    // MARK: - Provider resolution

    @Test func `an mdblist URL resolves to the mdblist provider`() {
        #expect(Self.popular.provider?.displayName == "MDBList")
    }

    @Test func `an unknown host resolves to no provider`() {
        let section = CustomHomeSection(title: "Nope", sourceURL: "https://example.com/lists/whatever")
        #expect(section.provider == nil)
    }
}
