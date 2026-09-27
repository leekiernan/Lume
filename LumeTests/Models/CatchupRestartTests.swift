import Foundation
@testable import Lume
import Testing

/// "Watch from Start" eligibility for the programme on air now — the rule the
/// channel list's long-press menu asks before offering a restart.
struct CatchupRestartTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func slot(startedAgo: TimeInterval, endsIn: TimeInterval) -> EPGSlot {
        EPGSlot(title: "News", start: now.addingTimeInterval(-startedAgo), end: now.addingTimeInterval(endsIn))
    }

    private func restart(_ slot: EPGSlot?, capable: Bool = true, days: Int = 7) -> EPGSlot? {
        CatchupRestart.programme(slot, now: now, catchupCapable: capable, archiveDays: days)
    }

    @Test func `in progress programme inside the archive is restartable`() {
        let programme = slot(startedAgo: 15 * 60, endsIn: 45 * 60)
        #expect(restart(programme) == programme)
    }

    @Test func `programme that has not started is not restartable`() {
        #expect(restart(slot(startedAgo: -60, endsIn: 3600)) == nil)
    }

    @Test func `programme that has ended is not restartable`() {
        #expect(restart(slot(startedAgo: 3600, endsIn: -60)) == nil)
    }

    @Test func `no guide data offers nothing`() {
        #expect(restart(nil) == nil)
    }

    @Test func `channel without catchup offers nothing`() {
        #expect(restart(slot(startedAgo: 600, endsIn: 600), capable: false) == nil)
    }

    /// A programme that began before the archive's reach can't be served from
    /// its start, however long it still has to run.
    @Test func `start outside the archive window is not restartable`() {
        #expect(restart(slot(startedAgo: 2 * 86400, endsIn: 600), days: 1) == nil)
        #expect(restart(slot(startedAgo: 86400, endsIn: 600), days: 1) != nil)
    }

    /// Matches `EPGProgramCell.isLive(at:)`: the start instant counts as on
    /// air, the end instant doesn't.
    @Test func `boundaries are start inclusive and end exclusive`() {
        #expect(restart(slot(startedAgo: 0, endsIn: 3600)) != nil)
        #expect(restart(slot(startedAgo: 3600, endsIn: 0)) == nil)
    }

    /// A guide gap has no programme to restart — the list only ever sees real
    /// listings, and a live gap cell in the guide isn't live (`isLive` is
    /// false for gaps), so the two surfaces agree.
    @Test func `guide gap cell is never live`() {
        let gap = EPGProgramCell(
            id: "gap", title: "", detail: "", start: now.addingTimeInterval(-600),
            end: now.addingTimeInterval(600), listingID: nil, isGap: true, width: 100
        )
        #expect(!gap.isLive(at: now))
        #expect(!gap.isReplayEligible(at: now))
    }

    // MARK: - LiveStream wrapper

    @Test @MainActor func `stream wrapper uses the channel's archive`() {
        let programme = slot(startedAgo: 600, endsIn: 600)
        let xtream = LiveStream(id: "r-1", streamId: 1, name: "Xtream", tvArchive: 1, tvArchiveDuration: 0)
        let noArchive = LiveStream(id: "r-2", streamId: 2, name: "Plain")
        let m3u = LiveStream(id: "r-3", streamId: 3, name: "M3U", tvArchive: 1, tvArchiveDuration: 7)
        m3u.directURL = "http://example.com/live/stream.m3u8"

        #expect(xtream.restartableProgramme(programme, now: now) == programme)
        #expect(xtream.restartableProgramme(slot(startedAgo: 2 * 86400, endsIn: 600), now: now) == nil)
        #expect(noArchive.restartableProgramme(programme, now: now) == nil)
        #expect(m3u.restartableProgramme(programme, now: now) == nil)
    }
}
