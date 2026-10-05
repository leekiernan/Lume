//
//  PlaylistSwitchPresentationMachine.swift
//  Lume
//
//  The visual lifetime of a playlist switch is deliberately independent of
//  catalog sync: the overlay must paint before the selection invalidates the
//  content views, then remain while the new scope settles.
//

nonisolated struct PlaylistSwitchPresentationMachine: Equatable {
    struct Request: Equatable {
        fileprivate let sequence: UInt
        let targetID: String
        let targetName: String
        let defersDueSync: Bool
    }

    private enum State: Equatable {
        case idle
        case presenting(Request)
        case settling(Request, dueSyncDeferralPending: Bool)
    }

    private var state: State = .idle
    private var nextSequence: UInt = 0

    var isSwitching: Bool {
        switch state {
        case .idle: false
        case .presenting, .settling: true
        }
    }

    var targetName: String {
        switch state {
        case .idle: ""
        case let .presenting(request), let .settling(request, _): request.targetName
        }
    }

    /// Starts the presentation. A second request cannot replace the visible
    /// target while the first one is still applying or settling.
    mutating func begin(
        targetID: String,
        targetName: String,
        defersDueSync: Bool
    ) -> Request? {
        guard case .idle = state else { return nil }
        nextSequence &+= 1
        let request = Request(
            sequence: nextSequence,
            targetID: targetID,
            targetName: targetName,
            defersDueSync: defersDueSync
        )
        state = .presenting(request)
        return request
    }

    /// Transitions from the first-frame presentation into the settling period.
    /// The request identity makes stale scheduled work a harmless no-op.
    mutating func apply(_ request: Request) -> Bool {
        guard case let .presenting(active) = state, active == request else { return false }
        state = .settling(request, dueSyncDeferralPending: request.defersDueSync)
        return true
    }

    /// Consumes a one-shot due-sync deferral only for the playlist this request
    /// actually selected. An unrelated selection can never inherit the flag.
    mutating func consumeDueSyncDeferral(for playlistID: String) -> Bool {
        guard case let .settling(request, true) = state, request.targetID == playlistID else { return false }
        state = .settling(request, dueSyncDeferralPending: false)
        return true
    }

    /// Finishes only the matching settling request.
    mutating func finish(_ request: Request) {
        guard case let .settling(active, _) = state, active == request else { return }
        state = .idle
    }
}
