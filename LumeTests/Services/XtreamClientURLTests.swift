import Foundation
@testable import Lume
import Testing

struct XtreamClientURLTests {
    private func makePlaylist(
        name: String = "Test",
        serverURL: String = "http://example.com:8080",
        username: String = "testuser",
        password: String = "testpass"
    ) -> Playlist {
        Playlist(name: name, serverURL: serverURL, username: username, password: password)
    }

    // MARK: - Authenticated request URLs

    @Test(arguments: ["", "/", "/panel", "/panel/"])
    func `API and guide append endpoints to the server path`(_ path: String) throws {
        let playlist = makePlaylist(serverURL: "https://example.com:8080\(path)")
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let api = try #require(XtreamClient.playerAPIURL(for: playlist))
        let guide = try #require(XtreamClient.xmltvURL(for: playlist))

        #expect(api.absoluteString == "https://example.com:8080\(prefix)player_api.php?username=testuser&password=testpass")
        #expect(guide.absoluteString == "https://example.com:8080\(prefix)xmltv.php?username=testuser&password=testpass")
    }

    @Test(arguments: [
        "get_live_categories", "get_vod_categories", "get_series_categories",
        "get_live_streams", "get_vod_streams", "get_series"
    ])
    func `category and digest endpoints use the same action assembly`(_ action: String) throws {
        let url = try #require(XtreamClient.playerAPIURL(for: makePlaylist(), action: action))
        #expect(url.absoluteString == "http://example.com:8080/player_api.php?username=testuser&password=testpass&action=\(action)")
    }

    @Test func `authentication omits action and series parameters follow it`() throws {
        let playlist = makePlaylist()
        let auth = try #require(XtreamClient.playerAPIURL(for: playlist))
        #expect(URLComponents(url: auth, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) == ["username", "password"])
        let series = try #require(XtreamClient.playerAPIURL(
            for: playlist, action: "get_series_info", parameters: [URLQueryItem(name: "series_id", value: "42")]
        ))
        #expect(series.absoluteString == "http://example.com:8080/player_api.php?username=testuser&password=testpass&action=get_series_info&series_id=42")
    }

    @Test func `API and guide retain existing query items fragments and credential escaping`() throws {
        let playlist = makePlaylist(
            serverURL: "https://example.com/panel?token=one%26two&username=proxy#guide",
            username: "user&name=é", password: "p?#% word"
        )
        let expected = [
            URLQueryItem(name: "token", value: "one&two"),
            URLQueryItem(name: "username", value: "proxy"),
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password)
        ]
        let api = try #require(XtreamClient.playerAPIURL(for: playlist, action: "get_series_info"))
        let guide = try #require(XtreamClient.xmltvURL(for: playlist))
        let apiComponents = try #require(URLComponents(url: api, resolvingAgainstBaseURL: false))
        let guideComponents = try #require(URLComponents(url: guide, resolvingAgainstBaseURL: false))

        #expect(apiComponents.queryItems == expected + [URLQueryItem(name: "action", value: "get_series_info")])
        #expect(guideComponents.queryItems == expected)
        #expect(apiComponents.fragment == "guide")
        #expect(guideComponents.fragment == "guide")
        #expect(apiComponents.path == "/panel/player_api.php")
        #expect(guideComponents.path == "/panel/xmltv.php")
    }

    @Test func `invalid server URLs remain invalid and guide requires a nonempty server`() {
        let invalid = makePlaylist(serverURL: "https://[invalid")
        #expect(XtreamClient.playerAPIURL(for: invalid) == nil)
        #expect(XtreamClient.xmltvURL(for: invalid) == nil)
        #expect(XtreamClient.xmltvURL(for: makePlaylist(serverURL: "")) == nil)
        // Preserve the API builder's historical relative-URL behavior. Validation
        // belongs to source entry/request handling, not this mechanical extraction.
        #expect(XtreamClient.playerAPIURL(for: makePlaylist(serverURL: ""))?.relativeString == "/player_api.php?username=testuser&password=testpass")
    }

    // MARK: - Movie URL

    @Test func `build movie URL standard`() {
        let playlist = makePlaylist()
        let movie = Movie(id: "t-123", streamId: 123, name: "Test", containerExtension: "mp4")
        let url = XtreamClient.buildMovieURL(for: movie, playlist: playlist)
        let expected = URL(string: "http://example.com:8080/movie/testuser/testpass/123.mp4")
        #expect(url == expected)
    }

    @Test func `build movie URL default extension`() {
        let playlist = makePlaylist()
        let movie = Movie(id: "t-456", streamId: 456, name: "No Ext")
        let url = XtreamClient.buildMovieURL(for: movie, playlist: playlist)
        let expected = URL(string: "http://example.com:8080/movie/testuser/testpass/456.mp4")
        #expect(url == expected)
    }

    @Test func `build movie URL special chars`() {
        let playlist = makePlaylist(username: "user@name", password: "p@ss!word")
        let movie = Movie(id: "t-789", streamId: 789, name: "Test", containerExtension: "mkv")
        let url = XtreamClient.buildMovieURL(for: movie, playlist: playlist)
        #expect(url?.absoluteString.contains("user@name") == true)
        #expect(url?.absoluteString.contains("p@ss!word") == true)
    }

    // MARK: - Episode URL

    @Test func `build episode URL`() {
        let playlist = makePlaylist()
        let episode = Episode(
            id: "e-1",
            episodeId: "999",
            title: "Test Episode",
            containerExtension: "mkv",
            seasonNum: 1,
            episodeNum: 1
        )
        let url = XtreamClient.buildEpisodeURL(for: episode, playlist: playlist)
        let expected = URL(string: "http://example.com:8080/series/testuser/testpass/999.mkv")
        #expect(url == expected)
    }

    @Test func `build episode URL default extension`() {
        let playlist = makePlaylist()
        let episode = Episode(
            id: "e-2",
            episodeId: "888",
            title: "No Ext",
            containerExtension: "mp4",
            seasonNum: 1,
            episodeNum: 2
        )
        let url = XtreamClient.buildEpisodeURL(for: episode, playlist: playlist)
        let expected = URL(string: "http://example.com:8080/series/testuser/testpass/888.mp4")
        #expect(url == expected)
    }

    // MARK: - Live Stream URL

    @Test func `build live stream URL default format`() {
        let playlist = makePlaylist()
        let stream = LiveStream(id: "l-1", streamId: 555, name: "Test Channel")
        let url = XtreamClient.buildLiveStreamURL(for: stream, playlist: playlist)
        let expected = URL(string: "http://example.com:8080/live/testuser/testpass/555.m3u8")
        #expect(url == expected)
    }

    @Test func `build live stream URLTS format`() {
        let playlist = makePlaylist()
        let stream = LiveStream(id: "l-2", streamId: 666, name: "TS Channel")
        let url = XtreamClient.buildLiveStreamURL(for: stream, playlist: playlist, format: .tsStream)
        let expected = URL(string: "http://example.com:8080/live/testuser/testpass/666.ts")
        #expect(url == expected)
    }

    // MARK: - Catchup URL

    @Test func `build catchup URL uses timeshift path with minutes`() throws {
        let playlist = makePlaylist()
        let stream = LiveStream(id: "l-3", streamId: 777, name: "Catchup Channel")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let url = try #require(XtreamClient.buildCatchupURL(for: stream, playlist: playlist, start: start, durationMinutes: 90))
        let string = url.absoluteString
        #expect(string.hasPrefix("http://example.com:8080/timeshift/testuser/testpass/90/"))
        #expect(string.hasSuffix("/777.ts"))
        // The start segment is the Xtream `Y-m-d:H-i` wall-clock format.
        #expect(string.range(of: #"/\d{4}-\d{2}-\d{2}:\d{2}-\d{2}/777\.ts$"#, options: .regularExpression) != nil)
    }

    @Test func `build catchup URL uses advertised server timezone`() throws {
        let stream = LiveStream(id: "l-4", streamId: 778, name: "Catchup Channel")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let utcPlaylist = makePlaylist()
        utcPlaylist.serverTimezone = "UTC"
        let newYorkPlaylist = makePlaylist()
        newYorkPlaylist.serverTimezone = "America/New_York"

        let utcURL = try #require(XtreamClient.buildCatchupURL(
            for: stream, playlist: utcPlaylist, start: start, durationMinutes: 60
        ))
        let newYorkURL = try #require(XtreamClient.buildCatchupURL(
            for: stream, playlist: newYorkPlaylist, start: start, durationMinutes: 60
        ))

        #expect(utcURL.absoluteString.contains("/2023-11-14:22-13/"))
        #expect(newYorkURL.absoluteString.contains("/2023-11-14:17-13/"))
    }

    @Test func `build catchup URL rejects non-positive duration`() {
        let playlist = makePlaylist()
        let stream = LiveStream(id: "l-5", streamId: 779, name: "Catchup Channel")
        #expect(XtreamClient.buildCatchupURL(for: stream, playlist: playlist, start: Date(), durationMinutes: 0) == nil)
    }

    // MARK: - Server URL trailing slash handling

    @Test func `build movie URL with trailing slash`() {
        let playlist = makePlaylist(serverURL: "http://example.com:8080/")
        let movie = Movie(id: "t-1", streamId: 1, name: "Test", containerExtension: "mp4")
        let url = XtreamClient.buildMovieURL(for: movie, playlist: playlist)
        #expect(url?.absoluteString == "http://example.com:8080//movie/testuser/testpass/1.mp4")
    }

    @Test func `build movie URL without trailing slash`() {
        let playlist = makePlaylist(serverURL: "http://example.com:8080")
        let movie = Movie(id: "t-1", streamId: 1, name: "Test", containerExtension: "mp4")
        let url = XtreamClient.buildMovieURL(for: movie, playlist: playlist)
        #expect(url?.absoluteString == "http://example.com:8080/movie/testuser/testpass/1.mp4")
    }
}
