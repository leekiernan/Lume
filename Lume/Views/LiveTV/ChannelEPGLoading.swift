import SwiftData
import SwiftUI

/// Both list layouts run the same bounded fetch and publication boundary.
/// Detached fetch cancellation is cooperative: the machine also rejects a
/// superseded completion even if SQLite finished after the view task changed.
enum ChannelEPGLoading {
    static func run(key: ChannelEPGLoadMachine.Key, machine: Binding<ChannelEPGLoadMachine>, container: ModelContainer) async {
        let now = Date()
        guard !Task.isCancelled, let request = machine.wrappedValue.begin(key, now: now) else { return }
        let answer = await Task.detached(priority: .userInitiated) {
            ChannelEPGLoader.load(container: container, channelIds: request.channelIDs, now: now)
        }.value
        guard !Task.isCancelled else {
            machine.wrappedValue.cancel(request)
            return
        }
        machine.wrappedValue.finish(request, with: answer)
    }
}
