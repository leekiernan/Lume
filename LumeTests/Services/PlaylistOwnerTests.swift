import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
@Suite(.readsGlobalState)
struct PlaylistOwnerTests {
    @Test func `array prefix lookup preserves legacy spelling without changing indexed player lookup`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "Owner", serverURL: "https://owner.test", username: "u", password: "p")
        playlist.id = try #require(UUID(uuidString: "ABCDEFAB-CDEF-4ABC-8ABC-ABCDEFABCDEF"))
        context.insert(playlist)
        try context.save()
        for suffix in ["-movie-17", "-series-17", "-live-17", "legacy"] {
            let id = playlist.id.uuidString + suffix
            #expect(PlaylistOwner.playlist(forContentID: id, in: [playlist])?.id == playlist.id)
            #expect(PlaylistOwner.playlist(forPrefixedID: id, in: context)?.id == playlist.id)
            #expect(PlaylistOwner.playlist(forContentID: id.lowercased(), in: [playlist]) == nil)
            #expect(PlaylistOwner.playlist(forPrefixedID: id.lowercased(), in: context) == nil)
        }
        // Array callers historically accept a bare UUID; the indexed player
        // contract requires a suffix. Do not tighten either during extraction.
        #expect(PlaylistOwner.playlist(forContentID: playlist.id.uuidString, in: [playlist])?.id == playlist.id)
        #expect(PlaylistOwner.playlist(forPrefixedID: playlist.id.uuidString, in: context) == nil)
    }

    @Test func `owner wins over either legacy fallback or active selection`() throws {
        let container = try makeTestContainer()
        let first = Playlist(name: "First", serverURL: "https://first.test", username: "first", password: "first")
        let owner = Playlist(name: "Owner", serverURL: "https://owner.test", username: "owner", password: "owner")
        container.mainContext.insert(first)
        container.mainContext.insert(owner)
        try container.mainContext.save()
        let playlists = [first, owner]
        let id = owner.contentIDPrefix + "movie-17"
        let movie = Movie(id: id, streamId: 17, name: "Movie", containerExtension: "mp4")
        for fallback: PlaylistOwner.Fallback in [.none, .firstAvailable] {
            let resolved = try #require(PlaylistOwner.playlist(forContentID: id, in: playlists, fallback: fallback))
            #expect(resolved.id == owner.id)
            let media = try #require(PlayableMedia.from(movie: movie, playlist: resolved))
            #expect(media.url.host == "owner.test")
            #expect(media.url.path == "/movie/owner/owner/17.mp4")
        }
        #expect(playlists.active(for: first.id.uuidString)?.id == first.id)
        #expect(playlists.owner(ofContentID: id)?.id == owner.id)
    }

    @Test func `strict lookup stays strict for deleted owners malformed ids and missing series`() {
        let playlist = Playlist(name: "Other", serverURL: "https://other.test", username: "u", password: "p")
        for id in [nil, "", "legacy-title", "\(UUID().uuidString)-series-17"] as [String?] {
            #expect(PlaylistOwner.playlist(forContentID: id, in: [playlist]) == nil)
            #expect(PlaylistOwner.playlist(forContentID: id, in: [playlist], fallback: .firstAvailable)?.id == playlist.id)
            if let id { #expect([playlist].owner(ofContentID: id) == nil) }
        }
    }

    @Test func `legacy fallback preserves caller order rather than choosing active or oldest`() {
        let oldest = Playlist(name: "Old", serverURL: "https://old.test", username: "u", password: "p")
        let first = Playlist(name: "First", serverURL: "https://first.test", username: "u", password: "p")
        oldest.addedAt = Date(timeIntervalSince1970: 1)
        first.addedAt = Date(timeIntervalSince1970: 2)
        let playlists = [first, oldest]
        #expect(playlists.active(for: "")?.id == oldest.id)
        #expect(PlaylistOwner.playlist(forContentID: "legacy", in: playlists, fallback: .firstAvailable)?.id == first.id)
        #expect(PlaylistOwner.playlist(forContentID: "legacy", in: Array(playlists.reversed()), fallback: .firstAvailable)?.id == oldest.id)
        #expect(PlaylistOwner.playlist(forContentID: "legacy", in: [], fallback: .firstAvailable) == nil)
        #expect(PlaylistOwner.playlist(forContentID: nil, in: []) == nil)
    }
}
