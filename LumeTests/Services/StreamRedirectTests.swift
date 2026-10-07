import Foundation
@testable import Lume
import Testing

@MainActor
struct StreamRedirectTests {
    private let provider = URL(string: "https://provider.test/series/user/pass/42.mkv")!

    private func media(
        url: URL? = nil,
        kind: PlayableMedia.Kind = .vod,
        headers: [String: String]? = nil
    ) -> PlayableMedia {
        PlayableMedia(
            id: "episode", url: url ?? provider, title: "Episode", subtitle: nil, posterURL: nil,
            kind: kind, startTime: 0, contentRef: .episode("episode"), httpHeaders: headers
        )
    }

    private func response(_ status: Int, location: String?) -> HTTPURLResponse {
        HTTPURLResponse(
            url: provider, statusCode: status, httpVersion: "HTTP/2",
            headerFields: location.map { ["Location": $0] }
        )!
    }

    @Test func `a temporary redirect resolves to its location`() {
        let target = StreamRedirect.target(
            of: response(302, location: "https://cdn.test:8443/live/play/TOKEN/42"), for: provider
        )
        #expect(target == URL(string: "https://cdn.test:8443/live/play/TOKEN/42"))
    }

    @Test func `a relative location resolves against the provider URL`() {
        let target = StreamRedirect.target(of: response(307, location: "/play/TOKEN/42"), for: provider)
        #expect(target == URL(string: "https://provider.test/play/TOKEN/42"))
    }

    @Test func `a direct stream has no target`() {
        #expect(StreamRedirect.target(of: response(206, location: nil), for: provider) == nil)
        #expect(StreamRedirect.target(of: response(200, location: "https://cdn.test/x"), for: provider) == nil)
    }

    @Test func `a redirect off HTTP is not followed`() {
        #expect(StreamRedirect.target(of: response(302, location: "rtmp://cdn.test/x"), for: provider) == nil)
        #expect(StreamRedirect.target(of: response(302, location: nil), for: provider) == nil)
    }

    @Test func `only movies and episodes over HTTP without headers are resolved`() {
        #expect(StreamRedirect.isEligible(media()))
        #expect(!StreamRedirect.isEligible(media(kind: .live)))
        #expect(!StreamRedirect.isEligible(media(headers: ["Authorization": "Basic x"])))
        #expect(!StreamRedirect.isEligible(media(url: URL(string: "lumestalker://placeholder"))))
        #expect(!StreamRedirect.isEligible(media(url: URL(fileURLWithPath: "/tmp/movie.mkv"))))
    }

    @Test func `an unresolved stream opens on its own URL`() {
        let cache = StreamRedirectCache()
        #expect(cache.target(for: provider) == provider)
    }

    @Test func `an ineligible stream is not resolved`() async {
        let cache = StreamRedirectCache()
        let live = media(kind: .live)
        await cache.prepare(live)
        #expect(cache.target(for: live.url) == live.url)
    }
}
