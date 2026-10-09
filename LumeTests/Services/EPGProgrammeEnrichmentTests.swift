import Foundation
@testable import Lume
import SwiftData
import Testing

struct EPGProgrammeEnrichmentTests {
    private func programme(channel: String = "external", title: String = "Secrets of the Dead", offset: TimeInterval = 0) -> ParsedProgramme {
        ParsedProgramme(
            channelId: channel, title: title, subtitle: "Episode", description: "External description", categories: ["Documentary"],
            start: Date(timeIntervalSince1970: 10000 + offset), end: Date(timeIntervalSince1970: 13600 + offset),
            artworkURL: "https://example.com/programme.jpg", releaseYear: "2026"
        )
    }

    private func listing(title: String = "Secrets of the Deadᴺᵉʷ", channel: String = "provider") -> EPGListing {
        EPGListing(
            id: "listing", channelId: channel, title: title, listingDescription: "Provider description",
            start: Date(timeIntervalSince1970: 10000), end: Date(timeIntervalSince1970: 13600), sourceID: UUID()
        )
    }

    @Test func `exact matches fill missing metadata without changing provider identity or times`() throws {
        let row = listing()
        let index = EPGProgrammeEnrichment.Index(programmes: [programme()], aliases: ["external": ["provider"]])
        #expect(try EPGProgrammeEnrichment.apply(index, to: row))
        #expect(row.title == "Secrets of the Deadᴺᵉʷ")
        #expect(row.channelId == "provider")
        #expect(row.start == Date(timeIntervalSince1970: 10000))
        #expect(row.end == Date(timeIntervalSince1970: 13600))
        #expect(row.listingDescription == "Provider description")
        #expect(row.subtitle == "Episode")
        #expect(row.category == "Documentary")
        #expect(row.artworkURL == "https://example.com/programme.jpg")
        #expect(row.releaseYear == "2026")
        #expect(try !(EPGProgrammeEnrichment.apply(index, to: row)))
    }

    @Test func `provider metadata always wins`() throws {
        let row = listing()
        row.subtitle = "Provider episode"
        row.category = "Drama"
        row.artworkURL = "https://example.com/provider.jpg"
        row.releaseYear = "1990"
        let index = EPGProgrammeEnrichment.Index(programmes: [programme()], aliases: ["external": ["provider"]])
        #expect(try !EPGProgrammeEnrichment.apply(index, to: row))
        #expect(row.enrichmentBaseline == nil)
        #expect(row.subtitle == "Provider episode")
        #expect(row.releaseYear == "1990")
    }

    @Test func `title channel and exact interval disagreements do not enrich`() throws {
        for candidate in [programme(title: "A Different Show"), programme(offset: 1), programme(channel: "unmapped")] {
            let row = listing()
            let index = EPGProgrammeEnrichment.Index(programmes: [candidate], aliases: ["external": ["provider"]])
            #expect(try !EPGProgrammeEnrichment.apply(index, to: row))
            #expect(row.artworkURL == nil)
        }
        let differentEnd = listing()
        differentEnd.end = differentEnd.end.addingTimeInterval(1)
        #expect(try !EPGProgrammeEnrichment.apply(.init(programmes: [programme()], aliases: ["external": ["provider"]]), to: differentEnd))
    }

    @Test func `disabling enrichment or losing an alias restores provider fields`() throws {
        let row = listing()
        #expect(try EPGProgrammeEnrichment.apply(.init(programmes: [programme()], aliases: ["external": ["provider"]]), to: row))
        #expect(try EPGProgrammeEnrichment.apply(.init(), to: row))
        #expect(row.enrichmentBaseline == nil)
        #expect(row.artworkURL == nil)
        #expect(row.subtitle == nil)
        #expect(row.listingDescription == "Provider description")
    }

    @Test func `a replacement supplement clears fields removed by the external source`() throws {
        let row = listing()
        #expect(try EPGProgrammeEnrichment.apply(.init(programmes: [programme()], aliases: ["external": ["provider"]]), to: row))
        var replacement = programme()
        replacement.artworkURL = nil
        #expect(try EPGProgrammeEnrichment.apply(.init(programmes: [replacement], aliases: ["external": ["provider"]]), to: row))
        #expect(row.artworkURL == nil)
        #expect(row.subtitle == "Episode")
    }

    @Test func `a provider refresh resets the enrichment baseline`() throws {
        let row = listing()
        #expect(try EPGProgrammeEnrichment.apply(.init(programmes: [programme()], aliases: ["external": ["provider"]]), to: row))
        row.update(from: programme(channel: "provider", title: "Provider replacement"), category: "Drama")
        #expect(row.enrichmentBaseline == nil)
        #expect(try !EPGProgrammeEnrichment.apply(.init(), to: row))
        #expect(row.title == "Provider replacement")
        #expect(row.category == "Drama")
        #expect(row.listingDescription == "External description")
    }

    @Test func `conflicting duplicate metadata is rejected regardless of document order`() throws {
        var conflicting = programme()
        conflicting.artworkURL = "https://example.com/different.jpg"
        for candidates in [[programme(), conflicting], [conflicting, programme()], [programme(), programme()]] {
            let row = listing()
            let changed = try EPGProgrammeEnrichment.apply(.init(programmes: candidates, aliases: ["external": ["provider"]]), to: row)
            #expect(changed == (candidates[0].artworkURL == candidates[1].artworkURL))
        }
    }

    @Test func `normalization removes only the known badge and punctuation not meaningful words`() {
        #expect(EPGProgrammeEnrichment.normalizedTitle("Secrets of the Deadᴺᵉʷ ") == "secretsofthedead")
        #expect(EPGProgrammeEnrichment.normalizedTitle("New Tricks") == "newtricks")
        #expect(EPGProgrammeEnrichment.normalizedTitle("Live: News") != EPGProgrammeEnrichment.normalizedTitle("News"))
    }

    @Test func `aliases require both station identity and provider ID and reject collisions`() {
        let verified = EPGEnrichmentStations.Channel(name: "US PBS (KQED) San Francisco", epgID: "PBSKQED.us")
        #expect(EPGEnrichmentStations.aliases(for: [verified]) == ["KQED-DT.us_locals1": ["PBSKQED.us"]])
        #expect(EPGEnrichmentStations.aliases(for: [verified, .init(name: "PBS Kids", epgID: "PBSKQED.us")]).isEmpty)
        #expect(EPGEnrichmentStations.aliases(for: [.init(name: verified.name, epgID: "unknown")]).isEmpty)
        #expect(EPGEnrichmentStations.aliases(for: [.init(name: "US PBS (KERA) Dallas", epgID: "PBSKEDT.us")]).isEmpty)
    }

    @Test func `merging feed indexes rejects conflicting metadata rather than choosing by download order`() throws {
        var conflicting = programme()
        conflicting.artworkURL = "https://example.com/different.jpg"
        let first = EPGProgrammeEnrichment.Index(programmes: [programme()], aliases: ["external": ["provider"]])
        let second = EPGProgrammeEnrichment.Index(programmes: [conflicting], aliases: ["external": ["provider"]])
        for indexes in [[first, second], [second, first]] {
            #expect(try !EPGProgrammeEnrichment.apply(.init(merging: indexes), to: listing()))
        }
    }

    @Test func `UK aliases require reviewed variants and never guess generic regions or event channels`() {
        let channels: [EPGEnrichmentStations.Channel] = [
            .init(name: "BBC TWO FHD", epgID: "BBCTwo.uk"), .init(name: "BBC TWO SD", epgID: "BBCTwo.uk"),
            .init(name: "BBC ONE", epgID: "BBCOne.uk"), .init(name: "ITV1 FHD", epgID: "itv1.uk"),
            .init(name: "TNT SPORTS 1 FHD 50FPS", epgID: "TNTSports1.uk"), .init(name: "Arsenal Match", epgID: "arsenal")
        ]
        #expect(EPGEnrichmentStations.aliases(for: channels, feed: .britain) == ["BBC.Two.HD.uk": ["BBCTwo.uk"], "TNT.Sports.1.HD.uk": ["TNTSports1.uk"]])
        let conflict = EPGEnrichmentStations.Channel(name: "BBC TWO NORTHERN IRELAND", epgID: "BBCTwo.uk")
        #expect(EPGEnrichmentStations.aliases(for: channels + [conflict], feed: .britain)["BBC.Two.HD.uk"] == nil)
    }

    @Test func `one external schedule enriches each quality variant without merging their provider rows`() throws {
        let index = EPGProgrammeEnrichment.Index(programmes: [programme()], aliases: ["external": ["provider", "providerHD"]])
        for channel in ["provider", "providerHD"] {
            let row = listing(channel: channel)
            #expect(try EPGProgrammeEnrichment.apply(index, to: row))
            #expect(row.channelId == channel)
            #expect(row.artworkURL == programme().artworkURL)
            #expect(try EPGProgrammeEnrichment.apply(.init(), to: row))
            #expect(row.artworkURL == nil)
        }
        #expect(try !EPGProgrammeEnrichment.apply(index, to: listing(channel: "other")))
    }

    @Test func `conflicting supplements reject every mapped quality variant`() throws {
        var conflicting = programme()
        conflicting.artworkURL = "https://example.com/different.jpg"
        for programmes in [[programme(), conflicting], [conflicting, programme()]] {
            let index = EPGProgrammeEnrichment.Index(programmes: programmes, aliases: ["external": ["provider", "providerHD"]])
            for channel in ["provider", "providerHD"] {
                #expect(try !EPGProgrammeEnrichment.apply(index, to: listing(channel: channel)))
            }
        }
    }

    @Test func `quality variants are verified independently and category scope cannot hide conflicting references`() {
        let channels: [EPGEnrichmentStations.Channel] = [
            .init(name: "Sky Sports F1 FHD", epgID: "SkySportsF1.uk"),
            .init(name: "Sky Sports F1 SD", epgID: "SkySportsF1.uk"),
            .init(name: "Sky Sports F1 HD", epgID: "skysportsf1.uk")
        ]
        let external = "SkySp.F1.HD.uk"
        #expect(EPGEnrichmentStations.aliases(for: channels, feed: .britain)[external] == ["SkySportsF1.uk", "skysportsf1.uk"])
        var scope = EPGEnrichmentScope(channels: channels, eligible: ["SkySportsF1.uk"])
        #expect(scope.aliases(for: .britain)[external] == ["SkySportsF1.uk"])
        scope.channels.append(.init(name: "Generic F1 Event", epgID: "SkySportsF1.uk"))
        #expect(scope.aliases(for: .britain).isEmpty)
        scope.eligible.insert("skysportsf1.uk")
        #expect(scope.aliases(for: .britain)[external] == ["skysportsf1.uk"])
    }

    @Test func `expanded UK registry has unique provider IDs and no inferred timeshifts or generic regions`() {
        let stations = EPGEnrichmentStations.ukStations
        #expect(Set(stations.map(\.providerID)).count == stations.count)
        #expect(Set(stations.map(\.externalID)).count == 143)
        #expect(stations.allSatisfy { !$0.names.isEmpty && !$0.externalID.isEmpty })
        let excluded = ["BBCOne.uk", "itv1.uk", "SkySportsMainEvent.uk", "SkySportsMix.uk"]
        #expect(EPGEnrichmentStations.providerIDs(for: .britain).isDisjoint(with: excluded))
        #expect(stations.allSatisfy { !$0.names.contains(where: { $0.contains("+1") }) })
    }

    @Test func `filtered SAX parsing only emits selected stations`() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("EPGEnrichmentParser-\(UUID()).xml")
        defer { try? FileManager.default.removeItem(at: file) }
        try """
        <tv>
          <programme start="20261009000000 +0000" stop="20261009010000 +0000" channel="other"><title>Wrong</title><desc>Other</desc></programme>
          <programme start="20261009000000 +0000" stop="20261009010000 +0000" channel="selected"><title>Right</title><sub-title>Episode</sub-title></programme>
        </tv>
        """.write(to: file, atomically: true, encoding: .utf8)
        var rows: [ParsedProgramme] = []
        let outcome = XMLTVParser.parse(fileURL: file, channelIDs: ["selected"]) { rows += $0 }
        #expect(outcome.succeeded)
        #expect(outcome.encounteredProgrammeCount == 2)
        #expect(rows.count == 1)
        #expect(rows.first?.title == "Right")
        #expect(rows.first?.subtitle == "Episode")
    }
}
