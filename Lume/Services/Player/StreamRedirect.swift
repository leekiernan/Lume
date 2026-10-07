import Foundation
import OSLog

/// Follows a VOD stream's provider redirect once, before KSPlayer opens it.
///
/// Many Xtream providers answer every request for a movie or episode with a
/// 302 to a CDN URL carrying a fresh token. FFmpeg's HTTP layer only caches a
/// redirect that comes with an expiry header, and these come without one, so
/// every seek during an open goes back to the provider first. An MKV start
/// with a resume point reads six places in the file (head, the index at the
/// end, the headers, the index again, the resume point), and each provider
/// round trip costs about 0.6 s. Opening the token URL directly skips all six.
///
/// The token stays valid while it's in use and for minutes after; what kills
/// one is the provider issuing a newer token for the same account. So a token
/// is only reused within the playback session that resolved it, and every
/// reconnect resolves again rather than trusting the old one.
nonisolated enum StreamRedirect {
    /// Long enough for a slow provider, short enough that a failed resolve
    /// costs the start little: FFmpeg would pay the same round trip anyway.
    static let timeout: TimeInterval = 4

    /// Movies and episodes over HTTP(S). Live streams open once and stay
    /// open, catch-up builds its own URLs, and streams with their own headers
    /// (WebDAV authorization) must not have them dropped across a redirect.
    static func isEligible(_ media: PlayableMedia) -> Bool {
        guard !media.isLive, media.catchup == nil, media.httpHeaders == nil else { return false }
        return isHTTP(media.url)
    }

    /// The URL `url` redirects to, or nil when it doesn't redirect or the
    /// request fails. Asks for a single byte so a direct stream costs nothing.
    static func resolve(_ url: URL) async -> URL? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            let (_, response) = try await URLSession.shared.data(for: request, delegate: RefuseRedirects())
            guard let http = response as? HTTPURLResponse else { return nil }
            return target(of: http, for: url)
        } catch {
            Logger.player.info("stream redirect: resolve failed (\(LogRedaction.describe(error), privacy: .public))")
            return nil
        }
    }

    /// Where a redirect response points, when it is one to an HTTP(S) URL.
    static func target(of response: HTTPURLResponse, for url: URL) -> URL? {
        guard [301, 302, 303, 307, 308].contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location"),
              let target = URL(string: location, relativeTo: url)?.absoluteURL,
              isHTTP(target)
        else { return nil }
        return target
    }

    private static func isHTTP(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased())
    }

    /// Hands the 3xx back instead of following it. The completion-handler
    /// form: the async one crashes the compiler's Objective-C thunk.
    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _: URLSession,
            task _: URLSessionTask,
            willPerformHTTPRedirection _: HTTPURLResponse,
            newRequest _: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}

/// The redirect targets resolved for this playback session, by original URL.
///
/// Written once per stream before the engine mounts and only read after, so
/// the URL KSPlayer is built with stays the same across view updates: a
/// changed URL would make `KSVideoPlayer` rebuild the session. Reconnects
/// resolve afresh through `StreamRedirect.resolve` without writing here.
final class StreamRedirectCache {
    static let shared = StreamRedirectCache()

    private var targets: [URL: URL] = [:]

    /// The URL to open for `url`: its resolved target, or `url` itself.
    func target(for url: URL) -> URL {
        targets[url] ?? url
    }

    /// Resolves `media`'s redirect ahead of the engine. A stream that doesn't
    /// redirect, or a resolve that fails, leaves the original URL in use.
    func prepare(_ media: PlayableMedia) async {
        guard StreamRedirect.isEligible(media) else { return }
        let target = await StreamRedirect.resolve(media.url)
        targets[media.url] = target
        Logger.player.info("stream redirect: \(target == nil ? "none, opening the provider URL" : "resolved, opening the token URL", privacy: .public)")
    }

    /// Ends the session: a later playback resolves a token of its own.
    func clear() {
        targets.removeAll()
    }
}
