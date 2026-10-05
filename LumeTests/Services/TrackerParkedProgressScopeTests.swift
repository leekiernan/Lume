import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
@Suite(.serialized, .globalState, .trackerIdentity(.trakt))
struct TraktParkedProgressScopeTests {
    @Test func `watched and paused episodes survive a cold save and disk reload`() throws {
        let originalDirectory = TraktPendingWatchedStore.directory
        try withMissingPendingDirectory { directory in
            TraktPendingWatchedStore.directory = directory
            TraktPendingWatchedStore.resetCacheForTesting()
            defer {
                TraktPendingWatchedStore.directory = originalDirectory
                TraktPendingWatchedStore.resetCacheForTesting()
            }
            var parked = TraktPendingWatchedStore.load()
            parked[300] = TraktPendingShow(episodes: ["1x2": 100], paused: ["1x3": .init(progress: 50, pausedAt: 100, parkedAt: 100)])
            TraktPendingWatchedStore.save(parked)
            let url = try #require(TraktPendingWatchedStore.fileURL)
            #expect(FileManager.default.fileExists(atPath: url.path))
            TraktPendingWatchedStore.resetCacheForTesting()
            #expect(TraktPendingWatchedStore.load() == parked)

            // Replacing an existing file must persist both halves, not just
            // change the in-memory copy.
            parked[300]?.episodes["1x2"] = 200
            TraktPendingWatchedStore.save(parked)
            TraktPendingWatchedStore.resetCacheForTesting()
            #expect(TraktPendingWatchedStore.load() == parked)

            TraktPendingWatchedStore.clear(tmdbID: 300)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            TraktPendingWatchedStore.resetCacheForTesting()
            #expect(TraktPendingWatchedStore.load().isEmpty)
        }
    }

    @Test func `save recreates a removed parent directory`() throws {
        let originalDirectory = TraktPendingWatchedStore.directory
        try withMissingPendingDirectory { directory in
            TraktPendingWatchedStore.directory = directory
            TraktPendingWatchedStore.resetCacheForTesting()
            defer {
                TraktPendingWatchedStore.directory = originalDirectory
                TraktPendingWatchedStore.resetCacheForTesting()
            }
            var parked = TraktPendingWatchedStore.load()
            parked[300] = TraktPendingShow(episodes: ["1x2": 100])
            TraktPendingWatchedStore.save(parked)
            try FileManager.default.removeItem(at: directory)
            parked[301] = TraktPendingShow(episodes: ["2x1": 200])
            TraktPendingWatchedStore.save(parked)
            TraktPendingWatchedStore.resetCacheForTesting()
            #expect(TraktPendingWatchedStore.load() == parked)
        }
    }

    @Test func `another account cannot replay or relabel parked watches and pauses`() throws {
        defer { TraktPendingWatchedStore.clearAll() }
        var parked = TraktPendingWatchedStore.load()
        parked[300] = TraktPendingShow(episodes: ["1x2": 100], paused: ["1x3": .init(progress: 50, pausedAt: 100, parkedAt: 100)])
        TraktPendingWatchedStore.save(parked)
        TraktPendingWatchedStore.resetCacheForTesting()
        let original = try #require(TraktAccountIdentityStore.load())
        TraktAccountIdentityStore.save(.init(username: "other", scope: "trakt:other"))
        #expect(TraktPendingWatchedStore.load().isEmpty)
        TraktPendingWatchedStore.save(parked) // A late import cannot relabel A as B.
        let series = scopeTestSeries()
        #expect(TraktWatchedImporter.applyPending(to: series, now: Date(timeIntervalSince1970: 101)) == 0)
        #expect(series.episodes.allSatisfy { !$0.isWatched && $0.watchProgress == 0 })
        TraktAccountIdentityStore.save(original)
        #expect(TraktPendingWatchedStore.load() == parked)
        #expect(TraktWatchedImporter.applyPending(to: series, now: Date(timeIntervalSince1970: 101)) == 1)
        #expect(series.episodes.first { $0.episodeNum == 3 }?.watchProgress == 600)
    }

    @Test func `legacy unstamped and unknown account state cannot authorize replay`() throws {
        defer { TraktPendingWatchedStore.clearAll() }
        let legacy = TraktPendingWatched(shows: ["300": TraktPendingShow(episodes: ["1x2": 100])], profileID: ActiveProfileStore.current)
        let url = try #require(TraktPendingWatchedStore.fileURL)
        try JSONEncoder().encode(legacy).write(to: url, options: .atomic)
        TraktPendingWatchedStore.resetCacheForTesting()
        #expect(TraktPendingWatchedStore.load().isEmpty)
        TraktAccountIdentityStore.clear()
        #expect(TraktPendingWatchedStore.load().isEmpty)
        #expect(!TrackerScope.trakt.matches(.trakt))
    }
}

@MainActor
@Suite(.serialized, .globalState, .trackerIdentity(.simkl))
struct SimklParkedProgressScopeTests {
    @Test func `watched episodes survive a cold save and disk reload`() throws {
        let originalDirectory = SimklPendingWatchedStore.directory
        try withMissingPendingDirectory { directory in
            SimklPendingWatchedStore.directory = directory
            SimklPendingWatchedStore.resetCacheForTesting()
            defer {
                SimklPendingWatchedStore.directory = originalDirectory
                SimklPendingWatchedStore.resetCacheForTesting()
            }
            var parked = SimklPendingWatchedStore.load()
            parked[300] = SimklPendingShow(episodes: ["1x2": 100])
            SimklPendingWatchedStore.save(parked)
            let url = try #require(SimklPendingWatchedStore.fileURL)
            #expect(FileManager.default.fileExists(atPath: url.path))
            SimklPendingWatchedStore.resetCacheForTesting()
            #expect(SimklPendingWatchedStore.load() == parked)

            parked[300]?.episodes["1x2"] = 200
            SimklPendingWatchedStore.save(parked)
            SimklPendingWatchedStore.resetCacheForTesting()
            #expect(SimklPendingWatchedStore.load() == parked)

            SimklPendingWatchedStore.clear(tmdbID: 300)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            SimklPendingWatchedStore.resetCacheForTesting()
            #expect(SimklPendingWatchedStore.load().isEmpty)
        }
    }

    @Test func `save recreates a removed parent directory`() throws {
        let originalDirectory = SimklPendingWatchedStore.directory
        try withMissingPendingDirectory { directory in
            SimklPendingWatchedStore.directory = directory
            SimklPendingWatchedStore.resetCacheForTesting()
            defer {
                SimklPendingWatchedStore.directory = originalDirectory
                SimklPendingWatchedStore.resetCacheForTesting()
            }
            var parked = SimklPendingWatchedStore.load()
            parked[300] = SimklPendingShow(episodes: ["1x2": 100])
            SimklPendingWatchedStore.save(parked)
            try FileManager.default.removeItem(at: directory)
            parked[301] = SimklPendingShow(episodes: ["2x1": 200])
            SimklPendingWatchedStore.save(parked)
            SimklPendingWatchedStore.resetCacheForTesting()
            #expect(SimklPendingWatchedStore.load() == parked)
        }
    }

    @Test func `another account cannot replay or relabel parked watched state`() throws {
        defer { SimklPendingWatchedStore.clearAll() }
        var parked = SimklPendingWatchedStore.load()
        parked[300] = SimklPendingShow(episodes: ["1x2": 100])
        SimklPendingWatchedStore.save(parked)
        SimklPendingWatchedStore.resetCacheForTesting()
        let original = try #require(SimklAccountIdentityStore.load())
        SimklAccountIdentityStore.save(.init(username: "other", scope: "simkl:other"))
        #expect(SimklPendingWatchedStore.load().isEmpty)
        SimklPendingWatchedStore.save(parked)
        let series = scopeTestSeries()
        #expect(SimklWatchedImporter.applyPending(to: series) == 0)
        #expect(series.episodes.allSatisfy { !$0.isWatched })
        SimklAccountIdentityStore.save(original)
        #expect(SimklPendingWatchedStore.load() == parked)
        #expect(SimklWatchedImporter.applyPending(to: series) == 1)
    }

    @Test func `legacy unstamped and unknown account state cannot authorize replay`() throws {
        defer { SimklPendingWatchedStore.clearAll() }
        let legacy = SimklPendingWatched(shows: ["300": SimklPendingShow(episodes: ["1x2": 100])], profileID: ActiveProfileStore.current)
        let url = try #require(SimklPendingWatchedStore.fileURL)
        try JSONEncoder().encode(legacy).write(to: url, options: .atomic)
        SimklPendingWatchedStore.resetCacheForTesting()
        #expect(SimklPendingWatchedStore.load().isEmpty)
        SimklAccountIdentityStore.clear()
        #expect(SimklPendingWatchedStore.load().isEmpty)
        #expect(!TrackerScope.simkl.matches(.simkl))
    }
}

/// Only the unique test root exists; even Application Support's intermediate
/// parent is deliberately absent, unlike the installed test fixture.
@MainActor
private func withMissingPendingDirectory(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PendingProgress-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("Library/Application Support", isDirectory: true)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    try body(directory)
}

@MainActor
private func scopeTestSeries() -> Series {
    let series = Series(id: "scope-show", seriesId: 1, name: "Show")
    series.tmdbId = 300
    series.episodes = [2, 3].map {
        let episode = Episode(id: "scope-\($0)", episodeId: "\($0)", title: "Episode", containerExtension: "mkv", seasonNum: 1, episodeNum: $0)
        episode.durationSecs = 1200
        return episode
    }
    return series
}
