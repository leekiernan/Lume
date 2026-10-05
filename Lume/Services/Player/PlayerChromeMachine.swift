import Foundation

/// Requested chrome only, not playback readiness, buffering or retry state.
/// One deadline owns hiding: pointer exit replaces inactivity, and later
/// activity invalidates either. Eligibility belongs to the engine host.
nonisolated struct PlayerChromeMachine {
    enum Deadline: Equatable {
        case inactivity, pointerExit

        var delay: Duration {
            switch self {
            case .inactivity: .seconds(4)
            case .pointerExit: .milliseconds(600)
            }
        }
    }

    struct Request: Equatable {
        fileprivate let token = RequestToken()
        let deadline: Deadline
    }

    private enum State {
        case hidden, visible, waiting(Request)
    }

    private var state: State = .visible

    var isVisible: Bool {
        if case .hidden = state { return false }
        return true
    }

    mutating func show() {
        state = .visible
    }

    mutating func hide() {
        state = .hidden
    }

    mutating func cancelDeadline() {
        if isVisible { state = .visible }
    }

    mutating func schedule(_ deadline: Deadline, mayHide: Bool) -> Request? {
        cancelDeadline()
        guard isVisible, mayHide else { return nil }
        let request = Request(deadline: deadline)
        state = .waiting(request)
        return request
    }

    /// A completed deadline is consumed even when the host is now pinned.
    /// Replaying it after playback resumes must never hide the controls.
    @discardableResult
    mutating func fire(_ request: Request, mayHide: Bool) -> Bool {
        guard case let .waiting(current) = state, current == request else { return false }
        state = mayHide ? .hidden : .visible
        return mayHide
    }
}
