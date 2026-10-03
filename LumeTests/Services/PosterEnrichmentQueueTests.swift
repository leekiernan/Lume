import Foundation
@testable import Lume
import Testing

struct PosterEnrichmentQueueTests {
    private final nonisolated class Catalog: Sendable {}

    private nonisolated func key(_ catalog: Catalog, _ id: String) -> PosterEnrichmentQueue.Key {
        .init(catalog: ObjectIdentifier(catalog), request: .init(kind: .movie, id: id, categoryID: nil), profile: nil, visibility: "visible")
    }

    @Test func `bounds concurrent lookups`() async {
        let queue = PosterEnrichmentQueue(limit: 2)
        let catalog = Catalog()
        let gate = Gate()
        let jobs = (0 ..< 3).map { index in
            Task {
                await queue.lookup(key(catalog, String(index))) {
                    await gate.run()
                    return PosterLookupResult(path: "/poster.jpg", checkedAt: .now)
                }
            }
        }
        await gate.waitForTwo()
        #expect(await gate.peak == 2)
        await gate.release()
        for job in jobs {
            #expect(await job.value?.path == "/poster.jpg")
        }
        #expect(await gate.total == 3)
        #expect(await gate.peak == 2)
    }

    @Test func `caches confirmed absence`() async {
        let queue = PosterEnrichmentQueue()
        let catalog = Catalog()
        let counter = Counter()
        let request = key(catalog, "missing")
        for _ in 0 ..< 2 {
            let result = await queue.lookup(request) {
                await counter.increment()
                return PosterLookupResult(path: nil, checkedAt: .now)
            }
            #expect(result != nil)
            #expect(result?.path == nil)
        }
        #expect(await counter.count == 1)
    }

    @Test func `shares concurrent requests`() async {
        let queue = PosterEnrichmentQueue()
        let catalog = Catalog()
        let request = key(catalog, "shared")
        let gate = Gate()
        let jobs = (0 ..< 12).map { _ in
            Task {
                await queue.lookup(request) {
                    await gate.run()
                    return PosterLookupResult(path: "/shared.jpg", checkedAt: .now)
                }
            }
        }
        await gate.waitForOne()
        await gate.release()
        for job in jobs {
            #expect(await job.value?.path == "/shared.jpg")
        }
        #expect(await gate.total == 1)
    }

    @Test func `expired miss can recover`() async {
        let queue = PosterEnrichmentQueue()
        let catalog = Catalog()
        let request = key(catalog, "expired")
        _ = await queue.lookup(request) {
            PosterLookupResult(path: nil, checkedAt: .distantPast)
        }
        let result = await queue.lookup(request) {
            PosterLookupResult(path: "/new.jpg", checkedAt: .now)
        }
        #expect(result?.path == "/new.jpg")
    }

    @Test func `visibility changes do not reuse results`() async {
        let queue = PosterEnrichmentQueue()
        let catalog = Catalog()
        let counter = Counter()
        let original = key(catalog, "movie")
        let changed = PosterEnrichmentQueue.Key(catalog: original.catalog, request: original.request, profile: UUID(), visibility: "changed")
        for request in [original, changed] {
            _ = await queue.lookup(request) {
                await counter.increment()
                return PosterLookupResult(path: "/poster.jpg", checkedAt: .now)
            }
        }
        #expect(await counter.count == 2)
    }

    @Test func `cancelled subscriber does not publish`() async {
        let queue = PosterEnrichmentQueue()
        let catalog = Catalog()
        let job = Task {
            await queue.lookup(key(catalog, "cancelled")) {
                try await Task.sleep(for: .seconds(60))
                return PosterLookupResult(path: "/poster.jpg", checkedAt: .now)
            }
        }
        job.cancel()
        #expect(await job.value == nil)
    }

    @Test func `running cancellation allows replacement`() async {
        let queue = PosterEnrichmentQueue(limit: 1)
        let catalog = Catalog()
        let request = key(catalog, "replacement")
        let gate = Gate()
        let original = Task {
            await queue.lookup(request) {
                // Deliberately ignores cancellation until released, like an
                // underlying transport that has not acknowledged it yet.
                await gate.run()
                return PosterLookupResult(path: "/old.jpg", checkedAt: .now)
            }
        }
        await gate.waitForOne()
        original.cancel()
        #expect(await original.value == nil)
        let replacement = Task {
            await queue.lookup(request) {
                PosterLookupResult(path: "/new.jpg", checkedAt: .now)
            }
        }
        await gate.release()
        #expect(await replacement.value?.path == "/new.jpg")
    }

    private actor Counter {
        var count = 0
        func increment() {
            count += 1
        }
    }

    private actor Gate {
        var total = 0
        var peak = 0
        private var active = 0
        private var released = false
        private var pending: [CheckedContinuation<Void, Never>] = []
        private var started: CheckedContinuation<Void, Never>?
        private var firstStarted: CheckedContinuation<Void, Never>?

        func run() async {
            total += 1
            active += 1
            peak = max(peak, active)
            if total == 1 { firstStarted?.resume(); firstStarted = nil }
            if total == 2 { started?.resume(); started = nil }
            if !released { await withCheckedContinuation { pending.append($0) } }
            active -= 1
        }

        func waitForTwo() async {
            if total < 2 { await withCheckedContinuation { started = $0 } }
        }

        func waitForOne() async {
            if total < 1 { await withCheckedContinuation { firstStarted = $0 } }
        }

        func release() {
            released = true
            for continuation in pending {
                continuation.resume()
            }
            pending.removeAll()
        }
    }
}
