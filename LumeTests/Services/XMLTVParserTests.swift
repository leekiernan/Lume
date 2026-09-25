//
//  XMLTVParserTests.swift
//  LumeTests
//
//  Covers the XMLTV signals the Sports Hub relies on: the streaming parser now
//  captures `<sub-title>`, accumulates every `<category>`, keeps one value per
//  repeated (multi-language) text element, and `XMLTVDate`
//  parses offset-less timestamps as UTC (per the XMLTV DTD) instead of dropping
//  the programme on the slow `DateFormatter` fallback. Also covers the parser's
//  own error/empty-guide reporting, which the sync pipeline relies on to tell a
//  malformed document from a genuinely empty one.
//

import Foundation
@testable import Lume
import Testing

// MARK: - Helpers

private func writeTempGuide(_ content: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".xml")
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func parseAll(_ content: String) throws -> [ParsedProgramme] {
    let url = try writeTempGuide(content)
    defer { try? FileManager.default.removeItem(at: url) }
    var programmes: [ParsedProgramme] = []
    _ = XMLTVParser.parse(fileURL: url, batchSize: 2000) { batch in
        programmes.append(contentsOf: batch)
    }
    return programmes
}

// MARK: - Parser

struct XMLTVParserTests {
    @Test func `a malformed document is not reported as a valid empty guide`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("XMLTVParserTests-\(UUID().uuidString).xml")
        try Data("<tv><programme".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let outcome = XMLTVParser.parse(fileURL: url) { _ in }

        #expect(!outcome.succeeded)
        #expect(outcome.programmeCount == 0)
    }

    @Test func `a non XMLTV document is not a valid empty guide`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("XMLTVParserTests-\(UUID().uuidString).xml")
        try Data("<error>provider unavailable</error>".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let outcome = XMLTVParser.parse(fileURL: url) { _ in }

        #expect(!outcome.succeeded)
        #expect(outcome.encounteredProgrammeCount == 0)
    }

    @Test func `unusable programmes are distinguishable from an empty guide`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("XMLTVParserTests-\(UUID().uuidString).xml")
        try Data("<tv><programme channel=\"news.1\"><title>Missing dates</title></programme></tv>".utf8)
            .write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let outcome = XMLTVParser.parse(fileURL: url) { _ in }

        #expect(outcome.succeeded)
        #expect(outcome.encounteredProgrammeCount == 1)
        #expect(outcome.programmeCount == 0)
    }

    @Test func `captures sub-title`() throws {
        let guide = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <programme start="20260918203000 +0000" stop="20260918220000 +0000" channel="sky.de">
            <title>Bundesliga</title>
            <sub-title>Bayern München - Borussia Dortmund</sub-title>
            <desc>Matchday 4.</desc>
          </programme>
        </tv>
        """
        let programmes = try parseAll(guide)
        let programme = try #require(programmes.first)
        #expect(programme.subtitle == "Bayern München - Borussia Dortmund")
        #expect(programme.title == "Bundesliga")
        #expect(programme.description == "Matchday 4.")
    }

    // MARK: Repeated (multi-language) text elements

    private static let bilingualGuide = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tv>
      <programme start="20260918200000 +0000" stop="20260918201500 +0000" channel="ard.de">
        <title lang="de">Tagesschau</title>
        <title lang="en">News</title>
        <sub-title lang="de">Nachrichten</sub-title>
        <sub-title lang="en">Headlines</sub-title>
        <desc lang="de">Die Nachrichten.</desc>
        <desc lang="en">The news.</desc>
      </programme>
    </tv>
    """

    private func parseAll(_ content: String, preferredLanguage: String?) throws -> [ParsedProgramme] {
        let url = try writeTempGuide(content)
        defer { try? FileManager.default.removeItem(at: url) }
        var programmes: [ParsedProgramme] = []
        _ = XMLTVParser.parse(fileURL: url, preferredLanguage: preferredLanguage) { batch in
            programmes.append(contentsOf: batch)
        }
        return programmes
    }

    @Test func `repeated elements are not concatenated`() throws {
        let programme = try #require(try parseAll(Self.bilingualGuide, preferredLanguage: nil).first)
        #expect(programme.title == "Tagesschau")
        #expect(programme.subtitle == "Nachrichten")
        #expect(programme.description == "Die Nachrichten.")
    }

    @Test func `repeated elements prefer the preferred language`() throws {
        let programme = try #require(try parseAll(Self.bilingualGuide, preferredLanguage: "en-GB").first)
        #expect(programme.title == "News")
        #expect(programme.subtitle == "Headlines")
        #expect(programme.description == "The news.")
    }

    @Test func `an unmatched preferred language keeps the first value`() throws {
        let programme = try #require(try parseAll(Self.bilingualGuide, preferredLanguage: "fr").first)
        #expect(programme.title == "Tagesschau")
    }

    @Test func `an empty first title does not hide a later one`() throws {
        let guide = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <programme start="20260918200000 +0000" stop="20260918201500 +0000" channel="ard.de">
            <title lang="de"></title>
            <title lang="en">News</title>
          </programme>
        </tv>
        """
        let programme = try #require(try parseAll(guide, preferredLanguage: "de").first)
        #expect(programme.title == "News")
    }

    @Test func `sub-title is nil when absent`() throws {
        let guide = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <programme start="20260918203000 +0000" stop="20260918220000 +0000" channel="sky.de">
            <title>News</title>
          </programme>
        </tv>
        """
        let programme = try #require(try parseAll(guide).first)
        #expect(programme.subtitle == nil)
        #expect(programme.categories.isEmpty)
    }

    @Test func `accumulates multiple categories`() throws {
        let guide = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <programme start="20260918203000 +0000" stop="20260918220000 +0000" channel="sky.de">
            <title>Bundesliga</title>
            <category>Sports</category>
            <category>Soccer</category>
            <category>Football</category>
          </programme>
        </tv>
        """
        let programme = try #require(try parseAll(guide).first)
        #expect(programme.categories == ["Sports", "Soccer", "Football"])
    }

    @Test func `blank categories are skipped`() throws {
        let guide = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <programme start="20260918203000 +0000" stop="20260918220000 +0000" channel="sky.de">
            <title>Bundesliga</title>
            <category>Sports</category>
            <category>   </category>
            <category>Soccer</category>
          </programme>
        </tv>
        """
        let programme = try #require(try parseAll(guide).first)
        #expect(programme.categories == ["Sports", "Soccer"])
    }

    @Test func `parses offset-less start as UTC and keeps the programme`() throws {
        let guide = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <programme start="20260918203000" stop="20260918220000" channel="sky.de">
            <title>Bundesliga</title>
          </programme>
        </tv>
        """
        let programme = try #require(try parseAll(guide).first)
        #expect(programme.start == XMLTVDate.parse("20260918203000 +0000"))
        #expect(programme.end == XMLTVDate.parse("20260918220000 +0000"))
    }

    @Test func `offset form is unchanged`() throws {
        let guide = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <programme start="20260918223000 +0200" stop="20260919000000 +0200" channel="sky.de">
            <title>Bundesliga</title>
          </programme>
        </tv>
        """
        let programme = try #require(try parseAll(guide).first)
        // +0200 20:30 local is 20:30 UTC (22:30 - 2h).
        #expect(programme.start == XMLTVDate.parse("20260918203000 +0000"))
    }
}

// MARK: - XMLTVDate

struct XMLTVDateTests {
    /// A fixed reference: 2026-09-18 20:30:00 UTC.
    private var reference: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 18
        components.hour = 20
        components.minute = 30
        components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    @Test func `canonical offset form parses`() {
        #expect(XMLTVDate.parse("20260918203000 +0000") == reference)
    }

    @Test func `positive offset is applied`() {
        // 22:30 at +0200 is the same instant as 20:30 UTC.
        #expect(XMLTVDate.parse("20260918223000 +0200") == reference)
    }

    @Test func `negative offset is applied`() {
        // 15:30 at -0500 is the same instant as 20:30 UTC.
        #expect(XMLTVDate.parse("20260918153000 -0500") == reference)
    }

    @Test func `offset-less 14 digit form is UTC`() {
        #expect(XMLTVDate.parse("20260918203000") == reference)
    }

    @Test func `offset-less 12 digit form is UTC with zero seconds`() {
        #expect(XMLTVDate.parse("202609182030") == reference)
    }

    @Test func `nil and empty return nil`() {
        #expect(XMLTVDate.parse(nil) == nil)
        #expect(XMLTVDate.parse("") == nil)
    }

    @Test func `out-of-range fields reject`() {
        #expect(XMLTVDate.parse("20261318203000") == nil) // month 13
        #expect(XMLTVDate.parse("20260918206000") == nil) // second 60
    }

    @Test func `non-canonical width still falls back to nil`() {
        // 8-digit date-only: neither the fast path nor the formatter accepts it.
        #expect(XMLTVDate.parse("20260918") == nil)
    }
}
