import Foundation
@testable import Lume
import Testing

/// What each stage of a stream's life does to the reconnect budget
/// (`PlaybackRetryController.Lifecycle`).
@MainActor
struct PlaybackRetryLifecycleTests {
    /// Two quick attempts, so a test can spend the budget.
    private func controller() -> PlaybackRetryController {
        PlaybackRetryController(backoff: [0.01, 0.01])
    }

    /// Schedules one retry and waits for it, returning whether it reloaded.
    private func retryFires(_ retry: PlaybackRetryController) async -> Bool {
        await withCheckedContinuation { continuation in
            var resumed = false
            retry.scheduleRetry {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: true)
            }
            guard !retry.hasGivenUp else {
                resumed = true
                continuation.resume(returning: false)
                return
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: false)
            }
        }
    }

    @Test func `a reconnect carries the budget on`() async {
        let retry = controller()
        #expect(await retryFires(retry))
        retry.handle(.reconnect)
        #expect(await retryFires(retry))
        retry.handle(.reconnect)
        #expect(await !retryFires(retry))
        #expect(retry.hasGivenUp)
    }

    @Test func `a new stream gets a full budget after the last one gave up`() async {
        let retry = controller()
        _ = await retryFires(retry)
        _ = await retryFires(retry)
        _ = await retryFires(retry)
        #expect(retry.hasGivenUp)

        retry.handle(.newStream)
        #expect(!retry.hasGivenUp)
        #expect(await retryFires(retry))
    }

    @Test func `a terminal failure stops a pending retry and any later one`() async throws {
        let retry = controller()
        var reloaded = false
        retry.scheduleRetry { reloaded = true }
        retry.handle(.terminalFailure)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!reloaded)

        // A later engine error after the overlay is up mustn't reload behind it.
        #expect(retry.hasGivenUp)
        #expect(await !retryFires(retry))
        // Queued KVO/delegate callbacks can arrive after the failure. Neither
        // health nor a same-stream reconnect authorizes dismissal/recovery.
        retry.reset()
        retry.handle(.reconnect)
        #expect(retry.hasGivenUp)
        #expect(await !retryFires(retry))
    }

    @Test func `a new stream or Try Again re-arms after a terminal failure`() async {
        let retry = controller()
        retry.handle(.terminalFailure)
        retry.handle(.newStream)
        #expect(await retryFires(retry))

        retry.handle(.terminalFailure)
        retry.handle(.manualRetry)
        #expect(await retryFires(retry))
    }

    @Test func `a reload before the first frame keeps the budget; only a new load refills it`() {
        #expect(PlaybackRetryController.lifecycle(forLoadReconnecting: true) == .reconnect)
        #expect(PlaybackRetryController.lifecycle(forLoadReconnecting: false) == .newStream)
    }

    @Test func `try Again gets a full budget`() async {
        let retry = controller()
        _ = await retryFires(retry)
        _ = await retryFires(retry)
        _ = await retryFires(retry)

        retry.handle(.manualRetry)
        #expect(await retryFires(retry))
    }

    @Test func `teardown stops a pending retry`() async throws {
        let retry = controller()
        var reloaded = false
        retry.scheduleRetry { reloaded = true }
        retry.handle(.teardown)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!reloaded)
    }
}
