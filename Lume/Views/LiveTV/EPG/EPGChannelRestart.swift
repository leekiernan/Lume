import Foundation

/// Uses the guide's existing snapshot, with no per-channel fetch. An open menu
/// cannot restart a different/finished programme or a newly unsupported stream.
enum EPGChannelRestart {
    static func action(
        for row: EPGChannelRow,
        now: Date = .now,
        currentDate: @escaping () -> Date = { .now },
        perform: @escaping (EPGProgramCell) -> Void
    ) -> (() -> Void)? {
        guard let cell = row.restartableCell(at: now) else { return nil }
        return {
            let date = currentDate()
            guard row.restartableCell(at: date)?.id == cell.id,
                  row.stream.restartableProgramme(EPGSlot(cell), now: date) != nil else { return }
            perform(cell)
        }
    }
}
