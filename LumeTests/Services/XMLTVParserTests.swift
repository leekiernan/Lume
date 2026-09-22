import Foundation
@testable import Lume
import Testing

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
}
