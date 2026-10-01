//
//  LiveProviderBenchmarks.swift
//  LumePerformanceTests
//
//  The production Xtream sync and guide import against a real provider's
//  catalog, served from a local snapshot so every run — and every tree being
//  compared — syncs byte-identical data without touching the provider.
//
//  Skipped unless `LUME_LIVE_XTREAM` names the snapshot server's base URL
//  (pass `TEST_RUNNER_LUME_LIVE_XTREAM=http://127.0.0.1:8765` to xcodebuild).
//  The generated fixtures elsewhere in this target say whether a phase got
//  slower; these say what a real catalog — its long tail of names, categories
//  and guide coverage — actually costs.
//

import Foundation
@testable import Lume
import SwiftData
import XCTest

final class LiveProviderBenchmarks: XCTestCase {
    private func serverURL() throws -> String {
        guard let url = ProcessInfo.processInfo.environment["LUME_LIVE_XTREAM"], !url.isEmpty else {
            throw XCTSkip("LUME_LIVE_XTREAM is not set")
        }
        return url
    }

    /// One run per iteration: a cold sync writes the whole catalog.
    private var singlePass: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        options.iterationCount = 1
        return options
    }

    func testLiveXtreamColdSync() throws {
        let server = try serverURL()
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: singlePass) {
            guard let store = try? PerfStore.makeOnDiskContainer(),
                  let playlistId = try? seedXtreamPlaylist(server: server, container: store.container)
            else {
                XCTFail("could not create the store")
                return
            }
            defer { PerfStore.destroy(directory: store.directory) }

            let manager = ContentSyncManager(modelContainer: store.container)
            startMeasuring()
            let outcome = syncPlaylistSynchronously(manager: manager, playlistId: playlistId, container: store.container)
            stopMeasuring()

            XCTAssertNil(outcome.error, "sync failed: \(String(describing: outcome.error))")
            assertCatalog(store.container, label: "cold")
        }
    }

    /// The sync a viewer pays for daily when nothing changed upstream.
    func testLiveXtreamUnchangedResync() throws {
        let server = try serverURL()
        guard let store = try? PerfStore.makeOnDiskContainer() else { return XCTFail("no store") }
        defer { PerfStore.destroy(directory: store.directory) }
        let playlistId = try seedXtreamPlaylist(server: server, container: store.container)
        let manager = ContentSyncManager(modelContainer: store.container)
        let first = syncPlaylistSynchronously(manager: manager, playlistId: playlistId, container: store.container)
        XCTAssertNil(first.error)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: singlePass) {
            startMeasuring()
            let outcome = syncPlaylistSynchronously(manager: manager, playlistId: playlistId, container: store.container)
            stopMeasuring()
            XCTAssertNil(outcome.error, "resync failed: \(String(describing: outcome.error))")
        }
        assertCatalog(store.container, label: "resync")
    }

    /// The provider's full XMLTV guide into a synced catalog.
    func testLiveGuideImport() throws {
        let server = try serverURL()
        guard let store = try? PerfStore.makeOnDiskContainer() else { return XCTFail("no store") }
        defer { PerfStore.destroy(directory: store.directory) }
        let playlistId = try seedXtreamPlaylist(server: server, container: store.container)
        let synced = syncPlaylistSynchronously(
            manager: ContentSyncManager(modelContainer: store.container),
            playlistId: playlistId,
            container: store.container
        )
        XCTAssertNil(synced.error)

        let context = ModelContext(store.container)
        context.insert(EPGSource(name: "Live guide", url: "\(server)/xmltv.php?username=u&password=p", playlistID: playlistId))
        try context.save()

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: singlePass) {
            let manager = EPGSyncManager(modelContainer: store.container)
            let finished = expectation(description: "guide")
            startMeasuring()
            Task.detached {
                _ = await manager.syncAllSources()
                finished.fulfill()
            }
            wait(for: [finished], timeout: 1800)
            stopMeasuring()
        }
        let listings = try ModelContext(store.container).fetchCount(FetchDescriptor<EPGListing>())
        print("LIVE-BENCH guide listings=\(listings)")
        XCTAssertGreaterThan(listings, 0, "no guide listings imported")
    }

    // MARK: - Harness

    private func seedXtreamPlaylist(server: String, container: ModelContainer) throws -> UUID {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let playlist = Playlist(name: "Live provider", serverURL: server, username: "u", password: "p")
        context.insert(playlist)
        try context.save()
        return playlist.id
    }

    private func assertCatalog(_ container: ModelContainer, label: String) {
        let context = ModelContext(container)
        let live = (try? context.fetchCount(FetchDescriptor<LiveStream>())) ?? 0
        let movies = (try? context.fetchCount(FetchDescriptor<Movie>())) ?? 0
        let series = (try? context.fetchCount(FetchDescriptor<Series>())) ?? 0
        let categories = (try? context.fetchCount(FetchDescriptor<Lume.Category>())) ?? 0
        print("LIVE-BENCH \(label) live=\(live) movies=\(movies) series=\(series) categories=\(categories)")
        XCTAssertGreaterThan(live, 0, "no live channels imported")
        XCTAssertGreaterThan(movies, 0, "no movies imported")
        XCTAssertGreaterThan(series, 0, "no series imported")
    }
}
