import Foundation
@testable import Lume
import Testing

private final nonisolated class TraktScrobbleStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var requests: [URLRequest] = []
    private nonisolated(unsafe) static var statusCode = 201
    private nonisolated(unsafe) static var responseBody = "{}"
    private nonisolated(unsafe) static var deleteStatusCode = 204

    static func reset(statusCode: Int = 201, responseBody: String = "{}", deleteStatusCode: Int = 204) {
        lock.withLock {
            requests = []
            Self.statusCode = statusCode
            Self.responseBody = responseBody
            Self.deleteStatusCode = deleteStatusCode
        }
    }

    static func recordedRequests() -> [URLRequest] {
        lock.withLock { requests }
    }

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        // Capture the body now: by the time a test reads the recorded request,
        // its body stream (see `URLRequest.bodyData`) may already be spent.
        var recorded = request
        recorded.httpBody = request.bodyData
        let (statusCode, responseBody) = Self.lock.withLock {
            Self.requests.append(recorded)
            if recorded.httpMethod == "DELETE" { return (Self.deleteStatusCode, "") }
            return (Self.statusCode, Self.responseBody)
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
@Suite(.serialized)
struct TraktScrobbleClientTests {
    @Test(arguments: [TraktScrobbleTarget.movie(tmdbID: 42), .episode(showTMDBID: 84, season: 1, episode: 2)])
    func `discard ends watching and removes only its returned playback entry`(target: TraktScrobbleTarget) async throws {
        TraktScrobbleStubProtocol.reset(responseBody: #"{"id":9876543210,"action":"pause","progress":1}"#)
        let response = try await makeClient().scrobble(target, action: .discard, progress: 0.7, accessToken: "token")
        let requests = TraktScrobbleStubProtocol.recordedRequests()
        #expect(requests.map(\.httpMethod) == ["POST", "DELETE"])
        #expect(requests.map { $0.url?.path } == ["/scrobble/stop", "/sync/playback/9876543210"])
        #expect(try requestJSON(requests[0])["progress"] as? Double == 1)
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(response.action == "discard" && response.progress == 0)
    }

    @Test func `discard tolerates an already deleted playback entry`() async throws {
        TraktScrobbleStubProtocol.reset(responseBody: #"{"id":42,"action":"pause","progress":1}"#, deleteStatusCode: 404)
        let response = try await makeClient().scrobble(.movie(tmdbID: 42), action: .discard, progress: 0, accessToken: "token")
        #expect(response.action == "discard")
    }

    @Test func `failed playback deletion is not reported as a successful discard`() async throws {
        TraktScrobbleStubProtocol.reset(responseBody: #"{"id":42,"action":"pause","progress":1}"#, deleteStatusCode: 500)
        do {
            try await makeClient().scrobble(.movie(tmdbID: 42), action: .discard, progress: 0, accessToken: "token")
            Issue.record("Expected deletion failure")
        } catch let error as TraktError {
            #expect(error == .server(500))
        }
    }

    @Test(arguments: [#"{"action":"pause","progress":1}"#, #"{"id":42,"action":"scrobble","progress":100}"#])
    func `discard never guesses an id or deletes a watched history entry`(body: String) async throws {
        TraktScrobbleStubProtocol.reset(responseBody: body)
        do {
            try await makeClient().scrobble(.movie(tmdbID: 42), action: .discard, progress: 0, accessToken: "token")
            Issue.record("Expected an invalid response")
        } catch let error as TraktError {
            #expect(error == .invalidResponse)
        }
        #expect(TraktScrobbleStubProtocol.recordedRequests().count == 1)
    }

    @Test func `normal stop retains its actual resume point`() async throws {
        TraktScrobbleStubProtocol.reset()
        try await makeClient().scrobble(.movie(tmdbID: 42), action: .stop, progress: 16.5, accessToken: "token")
        let requests = TraktScrobbleStubProtocol.recordedRequests()
        #expect(requests.count == 1)
        #expect(try requestJSON(requests[0])["progress"] as? Double == 16.5)
    }

    private func makeClient() -> TraktClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TraktScrobbleStubProtocol.self]
        return TraktClient(
            session: URLSession(configuration: config),
            clientID: "test-client-id",
            clientSecret: "test-client-secret"
        )
    }

    @Test func `starting a movie posts its TMDB id and progress`() async throws {
        TraktScrobbleStubProtocol.reset()

        try await makeClient().scrobble(
            .movie(tmdbID: 42), action: .start, progress: 12.5, accessToken: "token"
        )

        let request = try #require(TraktScrobbleStubProtocol.recordedRequests().first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/scrobble/start")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        let json = try requestJSON(request)
        #expect(json["progress"] as? Double == 12.5)
        let movie = try #require(json["movie"] as? [String: Any])
        let ids = try #require(movie["ids"] as? [String: Any])
        #expect(ids["tmdb"] as? Int == 42)
        #expect(json["show"] == nil)
        #expect(json["episode"] == nil)
    }

    @Test func `pausing an episode posts its show and episode numbers`() async throws {
        TraktScrobbleStubProtocol.reset()

        try await makeClient().scrobble(
            .episode(showTMDBID: 84, season: 3, episode: 7),
            action: .pause,
            progress: 51,
            accessToken: "token"
        )

        let request = try #require(TraktScrobbleStubProtocol.recordedRequests().first)
        #expect(request.url?.path == "/scrobble/pause")
        let json = try requestJSON(request)
        let show = try #require(json["show"] as? [String: Any])
        let ids = try #require(show["ids"] as? [String: Any])
        #expect(ids["tmdb"] as? Int == 84)
        let episode = try #require(json["episode"] as? [String: Any])
        #expect(episode["season"] as? Int == 3)
        #expect(episode["number"] as? Int == 7)
        #expect(json["movie"] == nil)
    }

    private func requestJSON(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test(arguments: [422, 429, 500])
    func `pause failures preserve HTTP status without logging response bodies`(status: Int) async throws {
        TraktScrobbleStubProtocol.reset(statusCode: status, responseBody: "private-response-marker")
        do {
            try await makeClient().scrobble(.movie(tmdbID: 42), action: .pause, progress: 0.3, accessToken: "private-token-marker")
            Issue.record("Expected an HTTP failure")
        } catch let error as TraktError {
            #expect(error == .server(status))
            #expect(LogRedaction.describe(error) == "TraktError: HTTP \(status)")
            #expect(!LogRedaction.describe(error).contains("private"))
        }
        let request = try #require(TraktScrobbleStubProtocol.recordedRequests().first)
        #expect(request.url?.path == "/scrobble/pause")
        #expect(try requestJSON(request)["progress"] as? Double == 0.3)
    }

    @Test func `pause authentication failures expose HTTP 401`() async throws {
        TraktScrobbleStubProtocol.reset(statusCode: 401)
        do {
            try await makeClient().scrobble(.movie(tmdbID: 42), action: .pause, progress: 25, accessToken: "token")
            Issue.record("Expected an authentication failure")
        } catch let error as TraktError {
            #expect(error == .notAuthenticated)
            #expect(LogRedaction.describe(error) == "TraktError: not authenticated (HTTP 401)")
        }
    }

    @Test func `malformed pause responses are distinguished from HTTP failures`() async throws {
        TraktScrobbleStubProtocol.reset(responseBody: "not JSON")
        do {
            try await makeClient().scrobble(.movie(tmdbID: 42), action: .pause, progress: 25, accessToken: "token")
            Issue.record("Expected a decoding failure")
        } catch let error as TraktError {
            #expect(error == .decoding)
            #expect(LogRedaction.describe(error) == "TraktError: response decoding failed")
        }
    }
}

@MainActor
struct TraktPlaybackScrobblerTests {
    private struct Event: Equatable {
        let target: TraktScrobbleTarget
        let action: TraktScrobbleAction
        let progress: Double
    }

    @Test func `play pause resume and stop emit one ordered lifecycle`() {
        var events: [Event] = []
        let scrobbler = TraktPlaybackScrobbler { target, action, progress in
            events.append(Event(target: target, action: action, progress: progress))
        }
        let movie = TraktScrobbleTarget.movie(tmdbID: 42)

        scrobbler.playbackStarted(target: movie, progress: 10)
        scrobbler.playbackStarted(target: movie, progress: 11)
        scrobbler.playbackPaused(target: movie, progress: 20)
        scrobbler.playbackPaused(target: movie, progress: 21)
        scrobbler.playbackStarted(target: movie, progress: 22)
        scrobbler.playbackStopped(target: movie, progress: 30)
        scrobbler.playbackStopped(target: movie, progress: 31)

        #expect(events == [
            Event(target: movie, action: .start, progress: 10),
            Event(target: movie, action: .pause, progress: 20),
            Event(target: movie, action: .start, progress: 22),
            Event(target: movie, action: .stop, progress: 30)
        ])
    }

    @Test func `changing targets settles the old session before starting the new one`() {
        var events: [Event] = []
        let scrobbler = TraktPlaybackScrobbler { target, action, progress in
            events.append(Event(target: target, action: action, progress: progress))
        }
        let movie = TraktScrobbleTarget.movie(tmdbID: 42)
        let episode = TraktScrobbleTarget.episode(showTMDBID: 84, season: 1, episode: 2)

        scrobbler.playbackStarted(target: movie, progress: 25)
        scrobbler.playbackStarted(target: episode, progress: 5)

        #expect(events == [
            Event(target: movie, action: .start, progress: 25),
            Event(target: movie, action: .stop, progress: 25),
            Event(target: episode, action: .start, progress: 5)
        ])
    }

    @Test func `progress is bounded and an immediate stop discards its resume point`() {
        #expect(TraktPlaybackScrobbler.progress(elapsed: 30, duration: 120) == 25)
        #expect(TraktPlaybackScrobbler.progress(elapsed: 150, duration: 120) == 100)
        #expect(TraktPlaybackScrobbler.progress(elapsed: 10, duration: 0) == 0)

        var events: [Event] = []
        let target = TraktScrobbleTarget.movie(tmdbID: 42)
        let scrobbler = TraktPlaybackScrobbler { target, action, progress in
            events.append(Event(target: target, action: action, progress: progress))
        }
        scrobbler.playbackStarted(target: target, progress: 0)
        scrobbler.playbackStopped(target: target, progress: 0)

        #expect(events.last == Event(target: target, action: .discard, progress: 0))
    }

    @Test func `early pause is skipped and exit discards once`() {
        var events: [Event] = []
        let target = TraktScrobbleTarget.movie(tmdbID: 42)
        let scrobbler = TraktPlaybackScrobbler { events.append(Event(target: $0, action: $1, progress: $2)) }
        scrobbler.playbackStarted(target: target, progress: 0)
        scrobbler.playbackPaused(target: target, progress: 0.7)
        scrobbler.playbackStopped(target: target, progress: 0.7)
        scrobbler.playbackStopped(target: target, progress: 0.7)
        #expect(events == [Event(target: target, action: .start, progress: 0), Event(target: target, action: .discard, progress: 0.7)])
    }

    @Test func `switching away from an early title discards only the outgoing session`() {
        var events: [Event] = []
        let first = TraktScrobbleTarget.movie(tmdbID: 42)
        let next = TraktScrobbleTarget.movie(tmdbID: 84)
        let scrobbler = TraktPlaybackScrobbler { events.append(Event(target: $0, action: $1, progress: $2)) }
        scrobbler.playbackStarted(target: first, progress: 0.7)
        scrobbler.playbackStarted(target: next, progress: 0)
        #expect(events == [
            Event(target: first, action: .start, progress: 0.7),
            Event(target: first, action: .discard, progress: 0.7),
            Event(target: next, action: .start, progress: 0)
        ])
    }

    @Test func `resume fallback yields to the engine including a backward seek`() {
        let clock = PlaybackClock()

        #expect(clock.elapsed(fallback: 600) == 600)

        // Engines commonly publish a preparatory zero before seeking to the
        // saved resume point. It must not turn a 50% resume into a 0% scrobble.
        clock.current = 0
        #expect(clock.elapsed(fallback: 600) == 600)

        clock.current = 605
        #expect(clock.elapsed(fallback: 600) == 605)

        // Once playback is established, a real seek behind the saved resume
        // point must win. The old max(current, startTime) logic got this wrong.
        clock.current = 120
        #expect(clock.elapsed(fallback: 600) == 120)
        clock.current = 0
        #expect(clock.elapsed(fallback: 600) == 0)

        clock.reset()
        #expect(clock.elapsed(fallback: 300) == 300)
    }
}

struct TraktScrobbleResponseTests {
    /// Logged after every scrobble, so a diagnostic report shows what Trakt
    /// took rather than only what was sent.
    @Test func `the response carries what Trakt recorded`() throws {
        let json = Data(#"{"id":0,"action":"pause","progress":11.5,"sharing":{"twitter":false}}"#.utf8)
        let response = try JSONDecoder().decode(TraktScrobbleResponse.self, from: json)
        #expect(response.action == "pause")
        #expect(response.progress == 11.5)
    }

    @Test func `an empty response still decodes`() throws {
        let response = try JSONDecoder().decode(TraktScrobbleResponse.self, from: Data("{}".utf8))
        #expect(response.action == nil)
    }
}
