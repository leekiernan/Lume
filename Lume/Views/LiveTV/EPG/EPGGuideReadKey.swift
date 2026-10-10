import Foundation

/// Equal-sized channel lists are not equal guide scopes. Clock rollover is
/// hourly here; the grid already advances its live highlight every minute.
nonisolated struct EPGGuideReadKey: Hashable {
    let scope: ChannelEPGLoadMachine.Scope
    let channelIDs: Set<String>
    var channelOrder: [String] = []
    let revision: UInt64
    let hour: Int
}
