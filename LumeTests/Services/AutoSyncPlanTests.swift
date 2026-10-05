import Foundation
@testable import Lume
import Testing

/// The auto-sync queue's decision for one playlist, including the
/// once-a-session area repair (`AutoSync.RepairLedger`).
struct AutoSyncPlanTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let playlistID = UUID()

    /// On screen, idle, refreshed an hour ago: not regularly due.
    private func candidate(isActive: Bool = true, status: SyncStatus = .idle) -> AutoSync.Candidate {
        AutoSync.Candidate(
            syncEnabled: true,
            status: status,
            lastSyncDate: now.addingTimeInterval(-3600),
            isActive: isActive,
            wasAddedThisSession: false
        )
    }

    private func plan(
        _ candidate: AutoSync.Candidate? = nil,
        alreadyStarted: Bool = false,
        stale: Set<AppArea>,
        ledger: AutoSync.RepairLedger = .init(),
        xtream: Bool = true,
        rows: Set<AppArea> = []
    ) -> AutoSync.Plan? {
        AutoSync.plan(
            AutoSync.PlanInput(
                candidate: candidate ?? self.candidate(),
                playlistID: playlistID,
                frequency: .daily,
                alreadyStarted: alreadyStarted,
                staleAreas: stale,
                supportsAreaRepair: xtream
            ),
            ledger: ledger,
            areasWithRows: { rows },
            now: now
        )
    }

    @Test func `a stale area is repaired even after this session's regular refresh`() {
        let repair = plan(alreadyStarted: true, stale: [.liveTV])
        #expect(repair == AutoSync.Plan(repairingAreas: [.liveTV], repairedAreas: [.liveTV], runsInBackground: false))
    }

    @Test func `a failed repair isn't retried on the next trigger`() {
        var ledger = AutoSync.RepairLedger()
        let first = plan(stale: [.liveTV], ledger: ledger, rows: [.liveTV])
        #expect(first?.runsInBackground == true)
        ledger.record(first?.repairedAreas ?? [], for: playlistID)

        // The area is still stale: the repair failed. The trigger fires again.
        #expect(plan(alreadyStarted: true, stale: [.liveTV], ledger: ledger, rows: [.liveTV]) == nil)
    }

    @Test func `a different area enabled later in the session still gets its repair`() {
        var ledger = AutoSync.RepairLedger()
        ledger.record([.liveTV], for: playlistID)

        let repair = plan(alreadyStarted: true, stale: [.liveTV, .series], ledger: ledger)
        #expect(repair?.repairingAreas == [.series])
    }

    @Test func `new connection details allow the repair again`() {
        var ledger = AutoSync.RepairLedger()
        ledger.record([.liveTV], for: playlistID)
        ledger.reset(playlistID)

        #expect(plan(stale: [.liveTV], ledger: ledger)?.repairingAreas == [.liveTV])
    }

    @Test func `the ledger is per playlist`() {
        var ledger = AutoSync.RepairLedger()
        ledger.record([.liveTV], for: UUID())

        #expect(plan(stale: [.liveTV], ledger: ledger)?.repairingAreas == [.liveTV])
    }

    @Test func `an area with nothing to browse blocks; one with rows refreshes behind`() {
        #expect(plan(stale: [.liveTV], rows: [.movies])?.runsInBackground == false)
        #expect(plan(stale: [.liveTV, .series], rows: [.liveTV])?.runsInBackground == false)
        #expect(plan(stale: [.liveTV], rows: [.liveTV, .movies])?.runsInBackground == true)
    }

    @Test func `a regularly due playlist gets its ordinary refresh and records no repair`() {
        let due = AutoSync.Candidate(
            syncEnabled: true, status: .idle, lastSyncDate: now.addingTimeInterval(-48 * 3600),
            isActive: true, wasAddedThisSession: false
        )
        #expect(plan(due, stale: [.liveTV]) == AutoSync.Plan(repairingAreas: nil, repairedAreas: [], runsInBackground: false))
    }

    @Test func `a source without per-area imports refreshes whole, once a session`() {
        var ledger = AutoSync.RepairLedger()
        let first = plan(stale: [.liveTV], ledger: ledger, xtream: false)
        #expect(first == AutoSync.Plan(repairingAreas: nil, repairedAreas: [.liveTV], runsInBackground: false))
        ledger.record(first?.repairedAreas ?? [], for: playlistID)

        #expect(plan(alreadyStarted: true, stale: [.liveTV], ledger: ledger, xtream: false) == nil)
    }

    @Test func `nothing for a playlist that isn't on screen or is already syncing`() {
        #expect(plan(candidate(isActive: false), stale: [.liveTV]) == nil)
        #expect(plan(candidate(status: .syncing), stale: [.liveTV]) == nil)
        #expect(plan(stale: []) == nil)
    }
}
