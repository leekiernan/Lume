//
//  SubtitleSearchStatusTests.swift
//  LumeTests
//
//  The results area shows one of five states, and both layouts (the iOS `List`
//  and the tvOS ten-foot column) switch on the same value — so the precedence
//  between them is worth pinning down here rather than in two view bodies.
//

@testable import Lume
import Testing

struct SubtitleSearchStatusTests {
    private var sample: OnlineSubtitle {
        OnlineSubtitle(
            id: "1",
            fileID: 2,
            languageCode: "en",
            releaseName: "Some.Release",
            downloadCount: 10,
            isHearingImpaired: false,
            isMachineTranslated: false,
            isFromTrusted: false,
            rating: 0
        )
    }

    @Test func `an initial search shows loading`() {
        var machine = SubtitleSearchMachine()
        _ = machine.begin(mediaID: "movie", supported: true)
        #expect(machine.status == .searching)
    }

    @Test func `an error outranks a stale result set`() {
        var machine = SubtitleSearchMachine()
        let initial = machine.begin(mediaID: "movie", supported: true)
        machine.finish(initial, results: [sample])
        let refresh = machine.begin(mediaID: "movie", supported: true)
        machine.fail(refresh, message: "boom")
        #expect(machine.status == .failed("boom"))
    }

    /// A live channel has nothing to search on, which is a different message
    /// from "searched and found nothing".
    @Test func `no query reads as unsupported, not empty`() {
        var machine = SubtitleSearchMachine()
        _ = machine.begin(mediaID: "live", supported: false)
        #expect(machine.status == .unsupported)
    }

    @Test func `a finished search with no hits is empty`() {
        var machine = SubtitleSearchMachine()
        let request = machine.begin(mediaID: "movie", supported: true)
        machine.finish(request, results: [])
        #expect(machine.status == .empty)
    }

    @Test func `hits win once everything else is clear`() {
        var machine = SubtitleSearchMachine()
        let request = machine.begin(mediaID: "movie", supported: true)
        machine.finish(request, results: [sample])
        #expect(machine.status == .results)
    }

    @Test func `language refresh retains results and rejects old success and failure`() {
        var machine = SubtitleSearchMachine()
        let initial = machine.begin(mediaID: "movie", supported: true)
        machine.finish(initial, results: [sample])
        let old = machine.begin(mediaID: "movie", supported: true)
        let current = machine.begin(mediaID: "movie", supported: true)
        #expect(machine.isSearching)
        #expect(machine.status == .results)
        #expect(machine.results == [sample])
        let outcome1 = machine.finish(old, results: [])
        #expect(!outcome1)
        let outcome2 = machine.fail(old, message: "old error")
        #expect(!outcome2)
        #expect(machine.isSearching)
        let outcome3 = machine.finish(current, results: [])
        #expect(outcome3)
        #expect(machine.status == .empty)
    }

    @Test func `changing media clears previous subtitles and invalidates a download`() throws {
        var machine = SubtitleSearchMachine()
        let search = machine.begin(mediaID: "first", supported: true)
        machine.finish(search, results: [sample])
        let outcome4 = machine.beginDownload(sample)
        let download = try #require(outcome4)
        _ = machine.begin(mediaID: "second", supported: true)
        #expect(machine.results.isEmpty)
        #expect(machine.downloadingID == nil)
        let outcome5 = machine.finishDownload(download)
        #expect(!outcome5)
    }

    @Test func `downloads are single flight and remain owned through language refresh`() throws {
        var machine = SubtitleSearchMachine()
        _ = machine.begin(mediaID: "movie", supported: true)
        let outcome6 = machine.beginDownload(sample)
        let download = try #require(outcome6)
        let outcome7 = machine.beginDownload(sample)
        #expect(outcome7 == nil)
        _ = machine.begin(mediaID: "movie", supported: true)
        let outcome8 = machine.finishDownload(download, error: "quota")
        #expect(outcome8)
        #expect(machine.downloadError == "quota")
        #expect(machine.downloadingID == nil)
        let outcome9 = machine.beginDownload(sample)
        #expect(outcome9 != nil)
        #expect(machine.downloadError == nil)
    }

    @Test func `dismissal rejects late search and download completion`() throws {
        var machine = SubtitleSearchMachine()
        let search = machine.begin(mediaID: "movie", supported: true)
        let outcome10 = machine.beginDownload(sample)
        let download = try #require(outcome10)
        machine.invalidate()
        let outcome11 = machine.finish(search, results: [sample])
        #expect(!outcome11)
        let outcome12 = machine.fail(search, message: "late")
        #expect(!outcome12)
        let outcome13 = machine.finishDownload(download, error: "late")
        #expect(!outcome13)
        #expect(machine.downloadError == nil)
        #expect(!machine.isSearching)
    }

    @Test func `unsupported media rejects results from the previous title`() {
        var machine = SubtitleSearchMachine()
        let previous = machine.begin(mediaID: "movie", supported: true)
        _ = machine.begin(mediaID: "live", supported: false)
        let accepted = machine.finish(previous, results: [sample])
        #expect(!accepted)
        #expect(machine.status == .unsupported)
        #expect(machine.results.isEmpty)
    }

    // MARK: - Badges

    @Test func `starting a download does not invalidate the active search`() throws {
        var machine = SubtitleSearchMachine()
        let search = machine.begin(mediaID: "movie", supported: true)
        let begun53 = machine.beginDownload(sample)
        let download = try #require(begun53)
        let accepted40 = machine.finish(search, results: [sample])
        #expect(accepted40)
        #expect(machine.downloadingID == sample.id)
        let accepted41 = machine.finishDownload(download)
        #expect(accepted41)
        #expect(machine.results == [sample])
    }

    @Test func `requests cannot cross search and download lanes`() throws {
        var machine = SubtitleSearchMachine()
        let search = machine.begin(mediaID: "movie", supported: true)
        let begun54 = machine.beginDownload(sample)
        let download = try #require(begun54)
        let accepted42 = machine.finishDownload(search, error: "wrong lane")
        #expect(!accepted42)
        let accepted43 = machine.finish(download, results: [])
        #expect(!accepted43)
        let accepted44 = machine.fail(download, message: "wrong lane")
        #expect(!accepted44)
        #expect(machine.isSearching)
        #expect(machine.downloadingID == sample.id)
        let accepted45 = machine.finish(search, results: [sample])
        #expect(accepted45)
        let accepted46 = machine.finishDownload(download)
        #expect(accepted46)
        let accepted47 = machine.finishDownload(download)
        #expect(!accepted47)
    }

    @Test func `recreated subtitle owner rejects previous search and download callbacks`() throws {
        var machine = SubtitleSearchMachine()
        let staleSearch = machine.begin(mediaID: "movie", supported: true)
        let begun55 = machine.beginDownload(sample)
        let staleDownload = try #require(begun55)
        machine = SubtitleSearchMachine()
        let search = machine.begin(mediaID: "movie", supported: true)
        let begun56 = machine.beginDownload(sample)
        let download = try #require(begun56)
        #expect(staleSearch != search)
        #expect(staleDownload != download)
        let accepted48 = machine.finish(staleSearch, results: [])
        #expect(!accepted48)
        let accepted49 = machine.fail(staleSearch, message: "stale")
        #expect(!accepted49)
        let accepted50 = machine.finishDownload(staleDownload)
        #expect(!accepted50)
        #expect(machine.isSearching)
        #expect(machine.downloadingID == sample.id)
        let accepted51 = machine.finish(search, results: [sample])
        #expect(accepted51)
        let accepted52 = machine.finishDownload(download)
        #expect(accepted52)
    }

    @Test func `badges surface only the flags that are set`() {
        var subtitle = sample
        #expect(subtitle.badges.isEmpty)

        subtitle = OnlineSubtitle(
            id: "1", fileID: 2, languageCode: "en", releaseName: "", downloadCount: 0,
            isHearingImpaired: true, isMachineTranslated: true, isFromTrusted: true, rating: 0
        )
        #expect(subtitle.badges.map(\.id) == ["cc", "trusted", "machine"])
    }
}
