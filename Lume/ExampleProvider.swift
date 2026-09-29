//
//  ExampleProvider.swift
//  Lume
//
//  The provider the unit-test host syncs instead of a real one. Tests build
//  their own data; the host app still launches the whole app around them, and
//  its auto-sync used to reach the viewer's real provider — a "Sync failed"
//  cover for the whole run whenever that playlist's details were stale.
//
//  A small m3u written to disk: the m3u pipeline imports `file://` playlists
//  in place, so the real sync runs end to end with no network. Stream URLs use
//  the reserved `.invalid` TLD, which never resolves, and nothing plays them.
//

import Foundation
import SwiftData

enum ExampleProvider {
    /// Fixed, so the per-playlist state keyed by id (the selected playlist,
    /// the skip-if-unchanged fingerprints) is reused run to run instead of
    /// piling up in `UserDefaults`.
    static let playlistID = UUID(uuidString: "E8A3F1C2-0D4B-4C6A-9E7F-5B2D1A0C3E91")!

    /// Adds the example playlist to `container`, writing its m3u first.
    static func seed(into container: ModelContainer) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lume-example-provider.m3u")
        do {
            try Data(m3u.utf8).write(to: file, options: .atomic)
        } catch {
            fatalError("Could not write the example provider's playlist: \(error)")
        }
        // The store is new every launch, but the fingerprints outlive it: left
        // in place they would match this same file and skip the import,
        // leaving the example catalog empty from the second run on.
        M3UDigestStore.remove(playlistId: playlistID)
        SweepSkipDefaults.removeAll(playlistId: playlistID)
        let context = ModelContext(container)
        let playlist = Playlist(name: "Example Provider", m3uURL: file.absoluteString)
        playlist.id = playlistID
        context.insert(playlist)
        try? context.save()
    }

    /// A live channel per group, two movies and a two-season series — one of
    /// each kind the m3u classifier sorts entries into.
    static let m3u = """
    #EXTM3U
    #EXTINF:-1 tvg-id="news.example" group-title="News",Example News
    http://provider.invalid/live/1.ts
    #EXTINF:-1 tvg-id="sport.example" group-title="Sport",Example Sport
    http://provider.invalid/live/2.ts
    #EXTINF:-1 tvg-id="kids.example" group-title="Kids",Example Kids
    http://provider.invalid/live/3.ts
    #EXTINF:-1 group-title="Movies",The Example (2024)
    http://provider.invalid/movie/101.mp4
    #EXTINF:-1 group-title="Movies",Another Example (2025)
    http://provider.invalid/movie/102.mp4
    #EXTINF:-1 group-title="Series",Example Show S01E01
    http://provider.invalid/series/201.mp4
    #EXTINF:-1 group-title="Series",Example Show S01E02
    http://provider.invalid/series/202.mp4
    #EXTINF:-1 group-title="Series",Example Show S02E01
    http://provider.invalid/series/203.mp4

    """
}
