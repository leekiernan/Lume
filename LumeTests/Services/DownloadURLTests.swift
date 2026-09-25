import Foundation
@testable import Lume
import Testing

/// Which URL a download starts from, per playlist source.
@MainActor
struct DownloadURLTests {
    private let built = URL(string: "http://example.com/movie/u/p/1.mp4")

    @Test func `m3u downloads the row's own URL`() {
        let playlist = Playlist(name: "M3U", m3uURL: "http://example.com/list.m3u")
        let url = DownloadManager.downloadURL(direct: "http://cdn.example.com/1.mkv", playlist: playlist) { built }
        #expect(url?.absoluteString == "http://cdn.example.com/1.mkv")
    }

    @Test func `xtream builds the URL from the account`() {
        let playlist = Playlist(name: "Xtream", serverURL: "http://example.com", username: "u", password: "p")
        let url = DownloadManager.downloadURL(direct: "http://ignored.example.com/1.mkv", playlist: playlist) { built }
        #expect(url == built)
    }

    @Test func `unsupported sources have no download URL`() {
        let playlist = Playlist(name: "Portal", portalURL: "http://portal.example", macAddress: "00:1A:79:00:00:01")
        let url = DownloadManager.downloadURL(direct: "http://cdn.example.com/1.mkv", playlist: playlist) { built }
        #expect(url == nil)
    }
}
