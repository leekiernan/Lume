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
}
