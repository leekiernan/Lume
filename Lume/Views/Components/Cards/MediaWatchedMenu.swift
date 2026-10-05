import Foundation
import SwiftUI

/// Incomplete content offers both finish and reset, rather than a boolean
/// toggle that only exposes reset after the viewer marks it watched first.
struct MediaWatchedMenu: View {
    nonisolated struct State: Equatable {
        let isWatched: Bool
        let progress: Double
        let lastWatchedDate: Date?

        var canMarkUnwatched: Bool {
            isWatched || progress > 0 || lastWatchedDate != nil
        }
    }

    let state: State
    let onSetWatched: (Bool) -> Void

    var body: some View {
        if !state.isWatched {
            Button { onSetWatched(true) } label: {
                Label("Mark as Watched", systemImage: "checkmark.circle")
            }
        }
        if state.canMarkUnwatched {
            Button { onSetWatched(false) } label: {
                Label("Mark as Unwatched", systemImage: "eye.slash")
            }
        }
    }
}
