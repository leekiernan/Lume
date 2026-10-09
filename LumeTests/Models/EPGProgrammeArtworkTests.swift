import Foundation
@testable import Lume
import SwiftData
import Testing

struct EPGProgrammeArtworkTests {
    @Test func `guide cells and now next snapshots retain programme artwork subtitles and synopsis`() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let row = EPGListing(id: "stable", channelId: "one", title: "Film", listingDescription: "Programme synopsis", start: start,
                             end: start.addingTimeInterval(3600), subtitle: "Episode title", artworkURL: "https://example.com/film.jpg")
        let window = EPGWindowListing(row)
        let timeline = EPGTimeline(start: start.addingTimeInterval(60), end: start.addingTimeInterval(7200), pointsPerMinute: 6)
        let cells = EPGGridBuilder.cells(for: [window], timeline: timeline)
        let cell = try #require(cells.first)
        #expect(cell.start == timeline.start)
        #expect(cell.detail == "Programme synopsis")
        #expect(cell.artworkURL == row.artworkURL)
        #expect(cell.subtitle == "Episode title")
        #expect(EPGSlot(cell).artworkURL == row.artworkURL)
        #expect(EPGSlot(window).subtitle == "Episode title")
        #expect(EPGSlot(row).subtitle == "Episode title")
        #expect(cells.last?.isGap == true)
        #expect(cells.last?.artworkURL == nil)
    }

    @Test func `selected programme lookup accepts clipped guide cells and exact hub fallbacks only`() throws {
        let container = try ModelContainer(for: EPGListing.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let row = EPGListing(id: "stable", channelId: "one", title: "Film", listingDescription: "Synopsis", start: start,
                             end: start.addingTimeInterval(3600), subtitle: "Episode", artworkURL: "https://example.com/film.jpg")
        container.mainContext.insert(row)
        try container.mainContext.save()
        let cell = EPGProgramCell(id: "grid-stable", title: "Film", detail: "", start: start.addingTimeInterval(60), end: row.end, listingID: "stable", isGap: false, width: 100)
        let details = try #require(try EPGProgrammeDetails.load(container: container, channelID: "one", cell: cell))
        #expect(details.synopsis == "Synopsis")
        #expect(details.artworkURL == row.artworkURL)
        #expect(details.subtitle == "Episode")
        #expect(try EPGProgrammeDetails.load(container: container, channelID: "other", cell: cell) == nil)
        let fallback = EPGProgramCell(id: "synthetic", title: "Film", detail: "", start: row.start, end: row.end, listingID: nil, isGap: false, width: 100)
        #expect(try EPGProgrammeDetails.load(container: container, channelID: "one", cell: fallback)?.synopsis == "Synopsis")
        let wrongTime = EPGProgramCell(id: "synthetic", title: "Film", detail: "", start: cell.start, end: row.end, listingID: nil, isGap: false, width: 100)
        #expect(try EPGProgrammeDetails.load(container: container, channelID: "one", cell: wrongTime) == nil)
    }

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
