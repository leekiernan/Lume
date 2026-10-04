import Foundation
@testable import Lume
import Testing

struct EPGChannelRestartTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func cell(_ id: String, start: TimeInterval, end: TimeInterval, gap: Bool = false) -> EPGProgramCell {
        EPGProgramCell(id: id, title: id, detail: "", start: now.addingTimeInterval(start), end: now.addingTimeInterval(end),
                       listingID: gap ? nil : id, isGap: gap, width: 100)
    }

    private func row(_ cells: [EPGProgramCell], capable: Bool = true, days: Int = 7) -> EPGChannelRow {
        let stream = LiveStream(id: "guide-test", streamId: 1, name: "Test", tvArchive: 1, tvArchiveDuration: days)
        return EPGChannelRow(id: stream.id, stream: stream, name: stream.name, category: nil, logoURL: nil,
                             catchupCapable: capable, archiveDays: days, cells: cells)
    }

    @Test func `guide restart selects the live cell rather than past future or gap cells`() throws {
        let live = cell("live", start: -600, end: 600)
        let channel = row([cell("past", start: -1800, end: -600), live, cell("future", start: 600, end: 1800)])
        #expect(channel.restartableCell(at: now) == live)
        var played: [String] = []
        let action = try #require(EPGChannelRestart.action(for: channel, now: now, currentDate: { now }, perform: { played.append($0.id) }))
        #expect(played.isEmpty)
        action()
        #expect(played == ["live"])
        #expect(row([cell("gap", start: -600, end: 600, gap: true)]).restartableCell(at: now) == nil)
    }

    @Test func `missing archive ended future and expired starts offer no restart`() {
        #expect(row([], capable: true).restartableCell(at: now) == nil)
        #expect(row([cell("live", start: -600, end: 600)], capable: false).restartableCell(at: now) == nil)
        #expect(row([cell("ended", start: -600, end: 0)]).restartableCell(at: now) == nil)
        #expect(row([cell("future", start: 1, end: 600)]).restartableCell(at: now) == nil)
        #expect(row([cell("old", start: -2 * 86400, end: 600)], days: 1).restartableCell(at: now) == nil)
    }

    @Test func `open menu cannot restart a finished programme or silently target its successor`() throws {
        let channel = row([cell("first", start: -600, end: 600), cell("second", start: 600, end: 1800)])
        var clock = now
        var played = false
        let action = try #require(EPGChannelRestart.action(for: channel, now: now, currentDate: { clock }, perform: { _ in played = true }))
        clock = now.addingTimeInterval(600)
        action()
        #expect(!played)
    }

    @Test func `open menu rechecks the stream capability before playback`() throws {
        let channel = row([cell("live", start: -600, end: 600)])
        var played = false
        let action = try #require(EPGChannelRestart.action(for: channel, now: now, currentDate: { now }, perform: { _ in played = true }))
        channel.stream.tvArchive = 0
        action()
        #expect(!played)
    }
}
