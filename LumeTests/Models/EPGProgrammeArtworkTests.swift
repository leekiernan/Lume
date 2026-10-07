import Foundation
@testable import Lume
import SwiftData
import Testing

struct EPGProgrammeArtworkTests {
    @Test func `programme metadata persists without changing listing identity`() throws {
        let container = try ModelContainer(for: EPGListing.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        context.insert(EPGListing(id: "stable", channelId: "one", title: "Film", listingDescription: "", start: .distantPast,
                                  end: .distantFuture, artworkURL: "https://example.com/film.jpg", releaseYear: "2021"))
        try context.save()
        let row = try #require(ModelContext(container).fetch(FetchDescriptor<EPGListing>()).first)
        #expect(row.id == "stable")
        #expect(row.artworkURL == "https://example.com/film.jpg")
        #expect(row.releaseYear == "2021")
    }

    @Test func `guide refresh replaces and clears old artwork and year`() {
        let listing = EPGListing(id: "stable", channelId: "one", title: "Film", listingDescription: "", start: .distantPast,
                                 end: .distantFuture, artworkURL: "https://example.com/old.jpg", releaseYear: "1984")
        var programme = ParsedProgramme(channelId: "one", title: "Film", subtitle: nil, description: "", categories: [],
                                        start: .distantPast, end: .distantFuture, artworkURL: "https://example.com/new.jpg", releaseYear: "2021")
        listing.update(from: programme, category: nil)
        #expect(listing.artworkURL == "https://example.com/new.jpg")
        #expect(listing.releaseYear == "2021")
        programme.artworkURL = nil
        programme.releaseYear = nil
        listing.update(from: programme, category: nil)
        #expect(listing.artworkURL == nil)
        #expect(listing.releaseYear == nil)
        #expect(listing.id == "stable")
    }
}
