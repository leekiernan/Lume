import Foundation
@testable import Lume
import Testing

private final nonisolated class TraktScrobbleStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        lock.withLock { requests = [] }
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
        Self.lock.withLock { Self.requests.append(recorded) }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
@Suite(.serialized)
struct TraktScrobbleClientTests {
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

    @Test func `progress is bounded and an immediate stop uses Trakt minimum`() {
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

        #expect(events.last == Event(target: target, action: .stop, progress: 1))
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
