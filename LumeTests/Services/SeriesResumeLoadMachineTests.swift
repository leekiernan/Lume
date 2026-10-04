import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct SeriesResumeLoadMachineTests {
    @Test func `keys track visibility identity and every stamp in the already observed window`() {
        let first = Series(id: "first", seriesId: 1, name: "First")
        let second = Series(id: "second", seriesId: 2, name: "Second")
        first.lastWatchedDate = Date(timeIntervalSince1970: 20)
        second.lastWatchedDate = Date(timeIntervalSince1970: 10)
        let original = key(watched: [first, second])
        second.lastWatchedDate = Date(timeIntervalSince1970: 15)
        #expect(original != key(watched: [first, second]))
        #expect(original != key(watched: [first]))
        #expect(original != key(watched: [first, Series(id: "third", seriesId: 3, name: "Third")]))
        #expect(original != key(prefix: "other-", watched: [first, second]))
        #expect(original != key(hidden: ["hidden"], watched: [first, second]))
        #expect(key(watched: [first]) != key(watched: [first], profile: UUID()))
    }

    @Test func `same scope retains a complete snapshot but changed visibility immediately hides it`() async throws {
        let container = try makeTestContainer()
        let lookup = SuspendedResumeLookup()
        let machine = SeriesResumeLoadMachine(lookup: { _ in await lookup.fetch() })
        let original = key()
        let first = Task { await machine.load(for: original, in: container) }
        let firstID = await lookup.nextRequest()
        await lookup.finish(firstID, with: ["show": 0.25])
        await first.value
        let refresh = Task { await machine.load(for: original, in: container) }
        let refreshID = await lookup.nextRequest()
        #expect(machine.snapshot(for: original).fractions == ["show": 0.25])
        #expect(machine.snapshot(for: key(hidden: ["category"])).fractions.isEmpty)
        #expect(machine.snapshot(for: key(prefix: "other-")).fractions.isEmpty)
        await lookup.finish(refreshID, with: ["show": 0.5])
        await refresh.value
        #expect(machine.snapshot(for: original).fractions == ["show": 0.5])
    }

    @Test func `returning to the original key still rejects late results from earlier requests`() async throws {
        let container = try makeTestContainer()
        let lookup = SuspendedResumeLookup()
        let machine = SeriesResumeLoadMachine(lookup: { _ in await lookup.fetch() })
        let original = key()
        let other = key(prefix: "other-")
        let first = Task { await machine.load(for: original, in: container) }
        let firstID = await lookup.nextRequest()
        let middle = Task { await machine.load(for: other, in: container) }
        let middleID = await lookup.nextRequest()
        let last = Task { await machine.load(for: original, in: container) }
        let lastID = await lookup.nextRequest()
        await lookup.finish(lastID, with: ["show": 0.75])
        await last.value
        await lookup.finish(firstID, with: ["show": 0.1])
        await lookup.finish(middleID, with: ["other": 0.2])
        await first.value
        await middle.value
        #expect(machine.snapshot(for: original).fractions == ["show": 0.75])
        #expect(machine.snapshot(for: other).fractions.isEmpty)
    }

    @Test func `cancelled lookup cannot publish or start the watch split`() async throws {
        let container = try makeTestContainer()
        let lookup = SuspendedResumeLookup()
        let machine = SeriesResumeLoadMachine(lookup: { _ in await lookup.fetch() })
        let requestKey = key()
        var splitCalls = 0
        let task = Task {
            await machine.load(for: requestKey, in: container) {
                splitCalls += 1
                return .init()
            }
        }
        let requestID = await lookup.nextRequest()
        task.cancel()
        await lookup.finish(requestID, with: ["show": 0.9])
        await task.value
        #expect(splitCalls == 0)
        #expect(machine.snapshot(for: requestKey).fractions.isEmpty)
    }

    @Test func `fractions and watch split publish atomically and cancellation rejects the suspended split`() async throws {
        let container = try makeTestContainer()
        let split = SuspendedResumeLookup()
        let machine = SeriesResumeLoadMachine(lookup: { _ in ["show": 0.5] })
        let requestKey = key()
        let task = Task {
            await machine.load(for: requestKey, in: container) {
                _ = await split.fetch()
                return .init(finished: ["finished"])
            }
        }
        let splitID = await split.nextRequest()
        #expect(machine.snapshot(for: requestKey).fractions.isEmpty)
        task.cancel()
        await split.finish(splitID, with: [:])
        await task.value
        #expect(machine.snapshot(for: requestKey).fractions.isEmpty)
        #expect(machine.snapshot(for: requestKey).progress.finished.isEmpty)

        await machine.load(for: requestKey, in: container) { .init(finished: ["finished"]) }
        #expect(machine.snapshot(for: requestKey).fractions == ["show": 0.5])
        #expect(machine.snapshot(for: requestKey).progress.finished == ["finished"])
    }

    @Test func `indexed resume query uses the latest unfinished episode and never substitutes for its missing duration`() throws {
        try OnDiskCatalogStore.withContext { context in
            let show = Series(id: "show", seriesId: 1, name: "Show")
            context.insert(show)
            for number in 1 ... 3 {
                let episode = Episode(id: "e\(number)", episodeId: "\(number)", title: "Episode", containerExtension: "mp4",
                                      seasonNum: 1, episodeNum: number, series: show)
                episode.watchProgress = Double(number * 10)
                episode.lastWatchedDate = Date(timeIntervalSince1970: Double(number))
                episode.durationSecs = 100
                episode.isWatched = number == 3
                context.insert(episode)
            }
            try context.save()
            #expect(SeriesResumeLoader.load(container: context.container) == ["show": 0.2])
            let episodes = try context.fetch(FetchDescriptor<Episode>())
            let latestUnfinished = try #require(episodes.first { $0.episodeNum == 2 })
            latestUnfinished.durationSecs = nil
            try context.save()
            #expect(SeriesResumeLoader.load(container: context.container).isEmpty)
        }
    }

    private func key(prefix: String = "playlist-", hidden: Set<String> = [], watched: [Series] = [], profile: UUID? = nil) -> SeriesResumeLoadKey {
        SeriesResumeLoadKey(playlistPrefix: prefix, restriction: ContentRestriction(hiddenCategoryIDs: hidden), watched: watched, profileID: profile)
    }
}

/// Deterministic handoff, not sleeps/polling; the cancelled operation can still
/// return so tests exercise the publication boundary itself.
private actor SuspendedResumeLookup {
    private var serial = 0
    private var pending: [Int: CheckedContinuation<[String: Double], Never>] = [:]
    private var started: [Int] = []
    private var waiter: CheckedContinuation<Int, Never>?

    func fetch() async -> [String: Double] {
        await withCheckedContinuation { continuation in
            serial += 1
            pending[serial] = continuation
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: serial)
            } else {
                started.append(serial)
            }
        }
    }

    func nextRequest() async -> Int {
        if !started.isEmpty { return started.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }

    func finish(_ id: Int, with result: [String: Double]) {
        pending.removeValue(forKey: id)?.resume(returning: result)
    }
}
