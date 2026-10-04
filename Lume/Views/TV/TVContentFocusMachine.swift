import Foundation

/// One owned handoff from Live TV's browse panel into its list or guide.
/// This does not own native focus, virtual guide navigation or scroll layout.
nonisolated struct TVContentFocusMachine {
    private(set) var request: TVContentFocusRequest?

    mutating func requestFocus(in scope: TVContentFocusRequest.Scope, channelID: String? = nil) {
        request = TVContentFocusRequest(scope: scope, channelID: channelID)
    }

    @discardableResult
    mutating func didClaim(_ completed: TVContentFocusRequest) -> Bool {
        guard request == completed else { return false }
        request = nil
        return true
    }

    mutating func cancel() {
        request = nil
    }
}

nonisolated struct TVContentFocusRequest: Equatable {
    struct Scope: Equatable {
        let playlistPrefix: String
        let channelScope: LiveChannelScope
        let visibilityToken: String
    }

    struct Landing: Hashable {
        let requestID: RequestToken
        let channelID: String
        /// Expand the lazy list before scrolling to a remembered row.
        let minimumVisibleCount: Int
    }

    let id = RequestToken()
    let scope: Scope
    var channelID: String?

    /// A synchronous channel query has settled without a native target. Consume
    /// this handoff rather than letting a later import unexpectedly steal focus.
    func emptyCompletion(in currentScope: Scope, hasChannels: Bool) -> Self? {
        scope == currentScope && !hasChannels ? self : nil
    }

    func landing(in currentScope: Scope, channelIDs: [String]) -> Landing? {
        guard scope == currentScope, !channelIDs.isEmpty else { return nil }
        let index = channelID.flatMap { channelIDs.firstIndex(of: $0) } ?? 0
        return Landing(requestID: id, channelID: channelIDs[index], minimumVisibleCount: index + 1)
    }
}
