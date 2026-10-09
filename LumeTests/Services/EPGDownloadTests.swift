import Foundation
@testable import Lume
import Synchronization
import Testing

struct EPGDownloadTests {
    @Test func `modification dates take precedence over etags and 304 retains the snapshot`() async throws {
        let request = Mutex("")
        let server = try GuideHTTPServer { raw in
            request.withLock { $0 = raw }
            return .init(status: 304)
        }
        defer { server.stop() }
        let url = try await server.start()
        let result = try await M3UClient().downloadGuide(from: url.absoluteString, lastModified: "Wed, 07 Oct 2026 12:00:00 GMT", entityTag: "etag")
        guard case .notModified = result else { Issue.record("Expected 304"); return }
        let raw = request.withLock { $0.lowercased() }
        #expect(raw.contains("if-modified-since:"))
        #expect(!raw.contains("if-none-match:"))
    }

    @Test func `etag fallback and servers ignoring validators are supported`() async throws {
        let request = Mutex("")
        let server = try GuideHTTPServer { raw in
            request.withLock { $0 = raw }
            return .init(headers: ["ETag": "new-tag", "Last-Modified": "Wed, 07 Oct 2026 12:00:00 GMT"])
        }
        defer { server.stop() }
        let url = try await server.start()
        let result = try await M3UClient().downloadGuide(from: url.absoluteString, entityTag: "old-tag")
        guard case let .file(file, modified, tag) = result else { Issue.record("Expected downloaded file"); return }
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "<tv></tv>")
        #expect(tag == "new-tag")
        #expect(modified == "Wed, 07 Oct 2026 12:00:00 GMT")
        #expect(request.withLock { $0.lowercased().contains("if-none-match: old-tag") })
    }

    @Test func `unsolicited 304 cannot bless a missing snapshot`() async throws {
        let server = try GuideHTTPServer { _ in .init(status: 304) }
        defer { server.stop() }
        let url = try await server.start()
        do {
            _ = try await M3UClient().downloadGuide(from: url.absoluteString)
            Issue.record("Unconditional 304 must fail")
        } catch M3UError.serverError(304) {
            // Expected: retry must obtain a real document.
        }
    }
}
