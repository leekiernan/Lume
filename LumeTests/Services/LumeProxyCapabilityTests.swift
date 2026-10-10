import Foundation
@testable import Lume
import Testing

@MainActor
struct LumeProxyCapabilityTests {
    private let valid = #"{"v":1,"metadata":{"v":1,"max_batch_size":50}}"#
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture(body: String, status: Int = 200) throws -> (Playlist, LumeProxySource, LumeProxyCapabilityStore, String) {
        let host = UUID().uuidString.lowercased() + ".example.com"
        let playlist = Playlist(name: "Test", serverURL: "https://\(host)/panel?token=one%26two", username: "test&user", password: "test?pass")
        let source = try #require(LumeProxySource(playlist: playlist))
        StubURLProtocol.register(host: host, pathSuffix: "/lume/v1/capabilities", response: .init(status: status, body: body))
        return (playlist, source, LumeProxyCapabilityStore(session: StubURLProtocol.makeSession()), host)
    }

    @Test func `capability URL retains base path query and escaped account`() throws {
        let (_, source, _, _) = try fixture(body: valid)
        let components = try #require(URLComponents(url: source.capabilitiesURL, resolvingAgainstBaseURL: false))
        #expect(components.path == "/panel/lume/v1/capabilities")
        #expect(components.queryItems == [
            URLQueryItem(name: "token", value: "one&two"),
            URLQueryItem(name: "username", value: "test&user"),
            URLQueryItem(name: "password", value: "test?pass")
        ])
        #expect(source.identity.count == 64)
        #expect(!source.identity.contains("test"))
    }

    @Test(arguments: ["", "ftp://example.com", "https://[invalid", "/panel"])
    func `invalid proxy base does not create a request`(_ url: String) {
        let playlist = Playlist(name: "Invalid", serverURL: url, username: "u", password: "p")
        #expect(LumeProxySource(playlist: playlist) == nil)
    }

    @Test func `supported capabilities are cached and manual refresh bypasses cache`() async throws {
        let (_, source, store, host) = try fixture(body: valid)
        let first = try await store.capabilities(for: source, now: now)
        guard case let .supported(capabilities) = first else {
            Issue.record("Expected supported v1 capabilities")
            return
        }
        #expect(capabilities.metadataBatchSize == 50)
        #expect(try await store.capabilities(for: source, now: now.addingTimeInterval(3599)) == first)
        #expect(StubURLProtocol.requests(forHost: host).count == 1)
        _ = try await store.capabilities(for: source, refresh: true, now: now)
        #expect(StubURLProtocol.requests(forHost: host).count == 2)
        let request = try #require(StubURLProtocol.requests(forHost: host).first)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.timeoutInterval == 3)
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func `supported cache expires rather than permanently enabling a route`() async throws {
        let (_, source, store, host) = try fixture(body: valid)
        _ = try await store.capabilities(for: source, now: now)
        StubURLProtocol.register(host: host, pathSuffix: "/lume/v1/capabilities", response: .init(status: 404))
        #expect(try await store.capabilities(for: source, now: now.addingTimeInterval(3600)) == .unsupported)
        #expect(StubURLProtocol.requests(forHost: host).count == 2)
    }

    @Test func `a 404 is unsupported but periodically reprobed for proxy upgrades`() async throws {
        let (_, source, store, host) = try fixture(body: "", status: 404)
        #expect(try await store.capabilities(for: source, now: now) == .unsupported)
        #expect(try await store.capabilities(for: source, now: now.addingTimeInterval(21599)) == .unsupported)
        #expect(StubURLProtocol.requests(forHost: host).count == 1)
        _ = try await store.capabilities(for: source, now: now.addingTimeInterval(21600))
        #expect(StubURLProtocol.requests(forHost: host).count == 2)
    }

    @Test(arguments: [401, 403, 429, 500, 503])
    func `transient HTTP failure is unavailable and retries on a short schedule`(_ status: Int) async throws {
        let (_, source, store, host) = try fixture(body: "", status: status)
        #expect(try await store.capabilities(for: source, now: now) == .unavailable)
        StubURLProtocol.register(host: host, pathSuffix: "/lume/v1/capabilities", response: .init(body: valid))
        #expect(try await store.capabilities(for: source, now: now.addingTimeInterval(59)) == .unavailable)
        guard case .supported = try await store.capabilities(for: source, now: now.addingTimeInterval(60)) else {
            Issue.record("A transient failure must not disable the proxy permanently")
            return
        }
        #expect(StubURLProtocol.requests(forHost: host).count == 2)
    }

    @Test(arguments: ["<html>panel</html>", "{}", #"{"v":"1"}"#, String(repeating: "x", count: 65537)])
    func `malformed or oversized response cannot enable metadata`(_ body: String) async throws {
        let (_, source, store, _) = try fixture(body: body)
        #expect(try await store.capabilities(for: source, now: now) == .unavailable)
    }

    @Test func `network failure is unavailable rather than unsupported`() async throws {
        let (playlist, _, store, _) = try fixture(body: valid)
        // No route for this host: the injected protocol fails immediately.
        playlist.serverURL = "https://\(UUID().uuidString).example.com"
        let source = try #require(LumeProxySource(playlist: playlist))
        #expect(try await store.capabilities(for: source, now: now) == .unavailable)
    }

    @Test func `unknown envelope version is unsupported`() async throws {
        let (_, source, store, _) = try fixture(body: #"{"v":2,"metadata":{"v":1,"max_batch_size":50}}"#)
        #expect(try await store.capabilities(for: source, now: now) == .unsupported)
    }

    @Test(arguments: [#"{"v":1}"#, #"{"v":1,"metadata":true}"#,
                      #"{"v":1,"metadata":{"v":2,"max_batch_size":50}}"#,
                      #"{"v":1,"metadata":{"v":1,"max_batch_size":0}}"#])
    func `optional metadata support is independently versioned and validated`(_ json: String) throws {
        let value = try JSONDecoder().decode(LumeProxyCapabilities.self, from: Data(json.utf8))
        #expect(value.metadataBatchSize == nil)
    }

    @Test func `batch size is bounded by the existing indexing chunk`() throws {
        let value = try JSONDecoder().decode(LumeProxyCapabilities.self, from: Data(#"{"v":1,"metadata":{"v":1,"max_batch_size":999999}}"#.utf8))
        #expect(value.metadataBatchSize == 50)
    }

    @Test(arguments: ["account", "password", "path", "query", "host"])
    func `provider identity changes invalidate capabilities`(_ field: String) async throws {
        let (playlist, source, store, host) = try fixture(body: valid)
        _ = try await store.capabilities(for: source, now: now)
        switch field {
        case "account": playlist.username = "other"
        case "password": playlist.password = "other"
        case "path": playlist.serverURL = "https://\(host)/other?token=one%26two"
        case "query": playlist.serverURL += "&second=2"
        default: playlist.serverURL = "https://other.\(host)"
        }
        let changed = try #require(LumeProxySource(playlist: playlist))
        #expect(changed.identity != source.identity)
        let changedHost = try #require(changed.capabilitiesURL.host)
        StubURLProtocol.register(host: changedHost, pathSuffix: "/lume/v1/capabilities", response: .init(status: 404))
        #expect(try await store.capabilities(for: changed, now: now) == .unsupported)
        let total = StubURLProtocol.requests(forHost: host).count + (changedHost == host ? 0 : StubURLProtocol.requests(forHost: changedHost).count)
        #expect(total == 2)
    }

    @Test func `concurrent consumers share negotiation`() async throws {
        let (_, source, store, host) = try fixture(body: valid)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 12 {
                group.addTask { _ = try await store.capabilities(for: source) }
            }
            try await group.waitForAll()
        }
        #expect(StubURLProtocol.requests(forHost: host).count == 1)
    }

    @Test func `a cancelled caller does not issue a request`() async throws {
        let (_, source, store, host) = try fixture(body: valid)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.capabilities(for: source)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(StubURLProtocol.requests(forHost: host).isEmpty)
    }
}
