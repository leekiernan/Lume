//
//  XtreamClient.swift
//  Lume
//
//  Xtream Codes API client
//

import Foundation
import OSLog

// MARK: - XtreamClient

/// `nonisolated` so the bulk catalog decodes stay off the main actor, and
/// `Sendable` because it holds nothing but its session: every request takes
/// the playlist it is for. The URL builders are static — building a playback
/// URL needs no client at all.
final nonisolated class XtreamClient: Sendable {
    let session: URLSession

    /// Every production client shares one session, so the one-connection-per-
    /// host cap below holds across them — a login check and a running sync
    /// queue for the same slot instead of racing for it.
    private static let sharedSession = makeSession()

    init(urlSession: URLSession? = nil) {
        session = urlSession ?? Self.sharedSession
    }

    /// Builds a dedicated session for Xtream API calls.
    ///
    /// Uses a single connection per host: many Xtream providers cap an account
    /// to one concurrent connection and reject extra requests with 401/403.
    /// Serializing connections (instead of reusing `.shared`'s pool, which the
    /// server may RST after a heavy transfer) avoids tripping that limit.
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 1
        config.timeoutIntervalForRequest = 30
        // `get_vod_streams` / `get_series` return a whole catalog in one body,
        // as large as the m3u exports `M3UClient` allows 600 s for, and slow
        // panels stream it slowly. The per-request idle timeout above still
        // catches a stalled transfer; this caps only one still making progress,
        // which at 120 s failed and then re-downloaded from scratch on retry.
        config.timeoutIntervalForResource = 600
        // Some panels only return JSON to a recognized player UA; the default
        // CFNetwork UA gets an HTML block page that fails to decode.
        config.httpAdditionalHeaders = ["User-Agent": lumeCatalogUserAgent]
        return URLSession(configuration: config)
    }

    // MARK: - Helper Methods

    /// The provider's XMLTV guide URL for a playlist (`xmltv.php` with the
    /// account credentials). Exposed so `EPGSourceReconciler` can store it as a
    /// standalone EPG source — the guide is no longer fetched during a playlist
    /// sync.
    static func xmltvURL(for playlist: Playlist) -> URL? {
        guard !playlist.serverURL.isEmpty else { return nil }
        var components = URLComponents(string: playlist.serverURL)
        guard components != nil else { return nil }
        if !(components?.path.hasSuffix("/") ?? false) {
            components?.path.append("/")
        }
        components?.path.append("xmltv.php")
        let existingItems = components?.queryItems ?? []
        components?.queryItems = existingItems + [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password)
        ]
        return components?.url
    }

    private func buildURL(serverURL: String, path: String, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents(string: serverURL)
        // Ensure the path is appended properly
        if !(components?.path.hasSuffix("/") ?? false), !path.hasPrefix("/") {
            components?.path.append("/")
        }
        components?.path.append(path)

        let existingItems = components?.queryItems ?? []
        components?.queryItems = existingItems + queryItems

        return components?.url
    }

    /// Signposts wrapping the two halves of a bulk request, so a trace can tell
    /// a slow transfer apart from a slow decode. Only the three catalog
    /// endpoints supply one; every other call leaves the phases unnamed.
    struct RequestPhases {
        let fetch: PerfSignpost
        let decode: PerfSignpost
    }

    /// Maximum number of attempts (1 initial + retries) for a single request.
    private static let maxAttempts = 3

    /// Performs a request with retry-and-backoff for transient failures.
    ///
    /// - Parameter action: constant API-action label (e.g. `get_live_streams`)
    ///   included in failure logs so diagnostics can pinpoint the endpoint.
    ///   Must never carry request parameters — logged as `privacy: .public`.
    /// - Parameter retryAuthFailure: when `true`, HTTP 401/403 is also treated
    ///   as transient. Sync/content calls set this because, after `getInfo`
    ///   has already proven the credentials, a 401/403 is almost always the
    ///   provider's connection/rate limit rather than bad credentials. Login
    ///   (`getInfo`) leaves it `false` so wrong credentials fail fast.
    private func request<T: Decodable & Sendable>(
        _ url: URL,
        action: String,
        retryAuthFailure: Bool = true,
        phases: RequestPhases? = nil
    ) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await performRequest(url, action: action, phases: phases)
            } catch let error as XtreamError {
                let retriable = error.isRetriable || (retryAuthFailure && error.isAuthFailure)
                guard retriable, attempt < Self.maxAttempts else {
                    Logger.network.error(
                        "Xtream \(action, privacy: .public) request failed permanently (\(error.logDescription, privacy: .public)) after \(attempt, privacy: .public) attempt(s)"
                    )
                    throw error
                }

                // Exponential backoff: 2s, then 4s. Gives the provider time to
                // release the connection slot / clear the rate-limit window.
                let delay = pow(2.0, Double(attempt))
                let reason = error.logDescription
                let retryLabel = "\(attempt)/\(Self.maxAttempts - 1)"
                Logger.network.warning(
                    "Xtream \(action, privacy: .public) failed (\(reason, privacy: .public)); retry \(retryLabel, privacy: .public) after \(delay, privacy: .public)s"
                )
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                Logger.network.warning(
                    "Xtream \(action, privacy: .public) backoff of \(delay, privacy: .public)s elapsed; retrying (attempt \(attempt + 1, privacy: .public))"
                )
            }
        }
    }

    /// A single request attempt. Network-level failures are wrapped into
    /// `XtreamError.networkError` so callers see a consistent error type.
    ///
    /// `@concurrent` is load-bearing: `SWIFT_APPROACHABLE_CONCURRENCY` runs a
    /// plain `nonisolated async` function on its caller's actor, so without it
    /// a login from a view would decode on the main actor, and a sync would hold
    /// `ContentSyncManager`'s executor through a multi-hundred-thousand-element
    /// `decoder.decode`.
    @concurrent
    private func performRequest<T: Decodable & Sendable>(
        _ url: URL,
        action: String,
        phases: RequestPhases? = nil
    ) async throws -> T {
        let data: Data
        let response: URLResponse
        let fetchInterval = phases.map { Perf.begin($0.fetch) }
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            if let fetchInterval { Perf.end(fetchInterval) }
            throw XtreamError.networkError(error)
        }
        if let fetchInterval { Perf.end(fetchInterval) }

        let byteCount = data.count
        Logger.network.info(
            "Xtream \(action, privacy: .public) payload \(byteCount, privacy: .public) bytes"
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            throw XtreamError.invalidResponse
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw XtreamError.authenticationFailed
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw XtreamError.serverError(httpResponse.statusCode)
        }

        let decodeInterval = phases.map { Perf.begin($0.decode) }
        defer { if let decodeInterval { Perf.end(decodeInterval) } }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(T.self, from: data)
        } catch {
            throw XtreamError.decodingError(error)
        }
    }

    // MARK: - API Methods

    /// 1. Get Server and User Info
    func getInfo(playlist: Playlist) async throws -> XtreamAuthResponse {
        let queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password)
        ]

        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }

        // Login: a 401/403 means bad credentials, so don't retry it.
        return try await request(url, action: "auth", retryAuthFailure: false)
    }

    /// 2. Get Live Categories
    func getLiveCategories(playlist: Playlist) async throws -> [XtreamCategory] {
        let queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: "get_live_categories")
        ]

        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }

        let list: XtreamList<XtreamCategory> = try await request(url, action: "get_live_categories")
        return list.items
    }

    /// 3. Get Live Streams
    func getLiveStreams(playlist: Playlist, categoryId: String? = nil) async throws -> [XtreamLiveStream] {
        var queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: "get_live_streams")
        ]
        if let categoryId {
            queryItems.append(URLQueryItem(name: "category_id", value: categoryId))
        }

        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }

        let list: XtreamList<XtreamLiveStream> = try await request(url, action: "get_live_streams", phases: RequestPhases(fetch: .xtreamFetchLiveStreams, decode: .xtreamDecodeLiveStreams))
        return list.items
    }

    /// 4. Get VOD Categories
    func getVODCategories(playlist: Playlist) async throws -> [XtreamCategory] {
        let queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: "get_vod_categories")
        ]

        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }

        let list: XtreamList<XtreamCategory> = try await request(url, action: "get_vod_categories")
        return list.items
    }

    /// 5. Get VOD Streams
    func getVODStreams(playlist: Playlist, categoryId: String? = nil) async throws -> [XtreamVODStream] {
        var queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: "get_vod_streams")
        ]
        if let categoryId {
            queryItems.append(URLQueryItem(name: "category_id", value: categoryId))
        }

        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }

        let list: XtreamList<XtreamVODStream> = try await request(url, action: "get_vod_streams", phases: RequestPhases(fetch: .xtreamFetchMovies, decode: .xtreamDecodeMovies))
        return list.items
    }

    /// 6. Get Series Categories
    func getSeriesCategories(playlist: Playlist) async throws -> [XtreamCategory] {
        let queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: "get_series_categories")
        ]

        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }

        let list: XtreamList<XtreamCategory> = try await request(url, action: "get_series_categories")
        return list.items
    }

    /// 7. Get Series
    func getSeries(playlist: Playlist, categoryId: String? = nil) async throws -> [XtreamSeries] {
        var queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: "get_series")
        ]
        if let categoryId {
            queryItems.append(URLQueryItem(name: "category_id", value: categoryId))
        }

        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }

        let list: XtreamList<XtreamSeries> = try await request(url, action: "get_series", phases: RequestPhases(fetch: .xtreamFetchSeries, decode: .xtreamDecodeSeries))
        return list.items
    }

    /// 8. Get Series Info
    func getSeriesInfo(playlist: Playlist, seriesId: Int) async throws -> XtreamSeriesInfoResponse {
        let queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: "get_series_info"),
            URLQueryItem(name: "series_id", value: String(seriesId))
        ]

        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }

        return try await request(url, action: "get_series_info")
    }

    // MARK: - Stream URL Building

    /// Builds a playback URL for a movie
    static func buildMovieURL(for movie: Movie, playlist: Playlist) -> URL? {
        let ext = movie.containerExtension ?? "mp4"
        return URL(string: "\(playlist.serverURL)/movie/\(playlist.username)/\(playlist.password)/\(movie.streamId).\(ext)")
    }

    /// Builds a playback URL for an episode
    static func buildEpisodeURL(for episode: Episode, playlist: Playlist) -> URL? {
        let ext = episode.containerExtension
        return URL(string: "\(playlist.serverURL)/series/\(playlist.username)/\(playlist.password)/\(episode.episodeId).\(ext)")
    }

    /// Builds a playback URL for a live stream. `format` overrides the
    /// playlist's own container preference; when omitted the playlist decides,
    /// falling back to HLS.
    static func buildLiveStreamURL(for stream: LiveStream, playlist: Playlist, format: StreamFormat? = nil) -> URL? {
        let ext = Self.resolvedFormat(format, playlist: playlist, fallback: .m3u8).rawValue
        return URL(string: "\(playlist.serverURL)/live/\(playlist.username)/\(playlist.password)/\(stream.streamId).\(ext)")
    }

    private static func resolvedFormat(
        _ requested: StreamFormat?,
        playlist: Playlist,
        fallback: StreamFormat
    ) -> StreamFormat {
        requested ?? playlist.streamFormat.xtreamFormat ?? fallback
    }

    /// `Y-m-d:H-i` is the start format Xtream Codes panels expect in a timeshift
    /// path. The value is wall-clock time in the timezone advertised by the
    /// account. Fall back to the device timezone for older panels that omit it,
    /// preserving Lume's historical behaviour for those providers.
    private static func timeshiftStartString(for start: Date, playlist: Playlist) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd:HH-mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = playlist.serverTimezone.flatMap(TimeZone.init(identifier:)) ?? .current
        return formatter.string(from: start)
    }

    /// Builds a catch-up / timeshift URL for a past programme on a live stream.
    ///
    /// Uses the Xtream Codes timeshift path
    /// `…/timeshift/user/pass/{durationMinutes}/{Y-m-d:H-i}/{streamId}.{ext}`,
    /// where the duration is the programme length in minutes and the start is the
    /// programme's air time. Only meaningful for Xtream streams (m3u channels
    /// carry no credentials).
    static func buildCatchupURL(
        for stream: LiveStream,
        playlist: Playlist,
        start: Date,
        durationMinutes: Int,
        format: StreamFormat? = nil
    ) -> URL? {
        guard durationMinutes > 0 else { return nil }
        // Xtream-compatible panels commonly expose catch-up as an MPEG-TS
        // resource even when normal live playback defaults to HLS. Respect an
        // explicit playlist/argument choice, but prefer TS when it is unknown.
        let ext = Self.resolvedFormat(format, playlist: playlist, fallback: .tsStream).rawValue
        let startString = Self.timeshiftStartString(for: start, playlist: playlist)
        return URL(string: "\(playlist.serverURL)/timeshift/\(playlist.username)/\(playlist.password)/\(durationMinutes)/\(startString)/\(stream.streamId).\(ext)")
    }
}

// MARK: - Supporting Types

nonisolated enum StreamFormat: String {
    case m3u8
    case tsStream = "ts"
}
