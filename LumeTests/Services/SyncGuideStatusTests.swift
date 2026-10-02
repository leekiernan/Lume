//
//  SyncGuideStatusTests.swift
//  LumeTests
//

@testable import Lume
import Testing

struct SyncGuideStatusTests {
    private func status(
        finished: Bool = true, failed: Bool = false, running: Bool = false, sawRunning: Bool = false, updated: Bool = false
    ) -> SyncGuideStatus {
        SyncGuideStatus.status(
            syncFinished: finished, syncFailed: failed, guideRunning: running,
            sawGuideRunning: sawRunning, guideUpdatedSinceSync: updated
        )
    }

    @Test func `waits for the sync, then updates, then is done`() {
        #expect(status(finished: false) == .afterSync)
        #expect(status() == .afterSync)
        #expect(status(running: true, sawRunning: true) == .updating)
        #expect(status(sawRunning: true, updated: true) == .updated)
    }

    @Test func `a failed sync or refresh leaves the guide as it was`() {
        #expect(status(finished: false, failed: true) == .notUpdated)
        #expect(status(sawRunning: true) == .notUpdated)
    }
}
