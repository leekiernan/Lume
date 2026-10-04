import Foundation
@testable import Lume
import Testing

struct ChannelEPGLoadMachineTests {
    @Test func `recreated guide owner rejects old completion and cancellation at the same scope`() throws {
        var machine = ChannelEPGLoadMachine()
        let old = try begin(&machine, key(["a"]))
        machine = ChannelEPGLoadMachine()
        let current = try begin(&machine, key(["a"]))
        #expect(old != current)
        machine.cancel(old)
        let accepted1 = machine.finish(old, with: ["a": pair])
        #expect(!accepted1)
        let accepted2 = machine.finish(current, with: ["a": pair])
        #expect(accepted2)
        let accepted3 = machine.finish(current, with: [:])
        #expect(!accepted3)
        #expect(machine.snapshot(for: scope()) == ["a": pair])
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let pair = ChannelEPG(current: EPGSlot(title: "On air", start: .distantPast, end: .distantFuture), next: nil)

    private func scope(
        _ ids: Set<String> = ["a", "b"], visibility: String = "parent", playlist: String = "playlist-", syncing: Bool = false
    ) -> ChannelEPGLoadMachine.Scope {
        .init(playlistPrefix: playlist, visibilityToken: visibility, channelScope: .favorites, channelIDs: ids, guideIsSyncing: syncing)
    }

    private func key(_ visible: Set<String>, scope: ChannelEPGLoadMachine.Scope? = nil) -> ChannelEPGLoadMachine.Key {
        .init(scope: scope ?? self.scope(), visibleChannelIDs: visible)
    }

    private func begin(
        _ machine: inout ChannelEPGLoadMachine, _ key: ChannelEPGLoadMachine.Key, at date: Date? = nil
    ) throws -> ChannelEPGLoadMachine.Request {
        let begun = machine.begin(key, now: date ?? now)
        return try #require(begun)
    }

    @Test func `pagination fetches only new channels including known empty answers`() throws {
        var machine = ChannelEPGLoadMachine()
        let first = try begin(&machine, key(["a"]))
        #expect(first.channelIDs == ["a"])
        machine.finish(first, with: [:])
        let next = try begin(&machine, key(["a", "b"]), at: now.addingTimeInterval(1))
        #expect(next.channelIDs == ["b"])
        machine.finish(next, with: ["b": pair])
        #expect(machine.snapshot(for: scope()) == ["b": pair])
        let unchanged = machine.begin(key(["a", "b"]), now: now.addingTimeInterval(2))
        #expect(unchanged == nil)
    }

    @Test func `extending preserves previous pairs without extending their freshness lifetime`() throws {
        var machine = ChannelEPGLoadMachine()
        let first = try begin(&machine, key(["a"]))
        machine.finish(first, with: ["a": pair])
        let next = try begin(&machine, key(["a", "b"]), at: now.addingTimeInterval(59))
        #expect(machine.snapshot(for: scope()) == ["a": pair])
        machine.finish(next, with: ["b": pair])
        #expect(machine.snapshot(for: scope()) == ["a": pair, "b": pair])
        let expired = try begin(&machine, key(["a", "b"]), at: now.addingTimeInterval(60))
        #expect(expired.channelIDs == ["a", "b"])
        machine.finish(expired, with: [:])
        #expect(machine.snapshot(for: scope()).isEmpty)
    }

    @Test func `a superseded page cannot replace the active snapshot`() throws {
        var machine = ChannelEPGLoadMachine()
        let old = try begin(&machine, key(["a"]))
        let current = try begin(&machine, key(["a", "b"]))
        let accepted = machine.finish(current, with: ["b": pair])
        let late = machine.finish(old, with: ["a": pair])
        #expect(accepted)
        #expect(!late)
        #expect(machine.snapshot(for: scope()) == ["b": pair])
    }

    @Test func `same sized channel replacements and guide updates invalidate the snapshot`() throws {
        let replacements = [scope(["c", "d"]), scope(syncing: true)]
        for replacement in replacements {
            var machine = ChannelEPGLoadMachine()
            let initial = try begin(&machine, key(["a"]))
            machine.finish(initial, with: ["a": pair])
            #expect(machine.snapshot(for: replacement).isEmpty)
            let current = try begin(&machine, key(replacement.channelIDs, scope: replacement))
            #expect(Set(current.channelIDs) == replacement.channelIDs)
            #expect(machine.snapshot(for: scope()).isEmpty)
        }
    }

    @Test func `profile or playlist changes hide old pairs before the replacement starts`() throws {
        for replacement in [scope(visibility: "child"), scope(playlist: "other-")] {
            var machine = ChannelEPGLoadMachine()
            let initial = try begin(&machine, key(["a"]))
            machine.finish(initial, with: ["a": pair])
            let oldRefresh = try begin(&machine, key(["a", "b"]))
            #expect(machine.snapshot(for: replacement).isEmpty)
            let current = try begin(&machine, key(["a"], scope: replacement))
            let late = machine.finish(oldRefresh, with: ["b": pair])
            #expect(!late)
            #expect(machine.snapshot(for: replacement).isEmpty)
            machine.finish(current, with: [:])
        }
    }

    @Test func `cancellation does not mark unfetched channels as complete`() throws {
        var machine = ChannelEPGLoadMachine()
        let request = try begin(&machine, key(["a"]))
        machine.cancel(request)
        let late = machine.finish(request, with: ["a": pair])
        #expect(!late)
        let retry = try begin(&machine, key(["a"]))
        #expect(retry.channelIDs == ["a"])
        machine.cancel(request)
        let accepted = machine.finish(retry, with: ["a": pair])
        #expect(accepted)
    }

    @Test func `an empty list clears pairs and rejects an outstanding fetch`() throws {
        var machine = ChannelEPGLoadMachine()
        let first = try begin(&machine, key(["a"]))
        machine.finish(first, with: ["a": pair])
        let pending = try begin(&machine, key(["a", "b"]))
        let empty = machine.begin(key([""]), now: now)
        let late = machine.finish(pending, with: ["b": pair])
        #expect(empty == nil)
        #expect(!late)
        #expect(machine.snapshot(for: scope()).isEmpty)
    }

    @Test func `a backwards clock invalidates cached pairs`() throws {
        var machine = ChannelEPGLoadMachine()
        let first = try begin(&machine, key(["a"]))
        machine.finish(first, with: ["a": pair])
        let request = try begin(&machine, key(["a"]), at: now.addingTimeInterval(-1))
        #expect(request.channelIDs == ["a"])
    }

    @Test func `ten pages fetch each channel once rather than refetching their prefixes`() throws {
        let ids = (0 ..< 500).map { "channel-\($0)" }
        let listScope = scope(Set(ids))
        var machine = ChannelEPGLoadMachine()
        var fetched: [String] = []
        for page in 1 ... 10 {
            let request = try begin(&machine, key(Set(ids.prefix(page * 50)), scope: listScope))
            #expect(request.channelIDs.count == 50)
            fetched.append(contentsOf: request.channelIDs)
            machine.finish(request, with: [:])
        }
        #expect(fetched.count == 500)
        #expect(Set(fetched) == Set(ids))
    }
}
