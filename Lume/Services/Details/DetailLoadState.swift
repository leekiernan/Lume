import Foundation

/// A detail lane's publication boundary, not an async loader. Movie and Series
/// machines own their distinct work; this only arbitrates request lifetimes.
nonisolated struct DetailLoadState {
    struct Request: Equatable {
        fileprivate let id = UUID()
    }

    private enum State {
        case idle(blocking: Bool)
        case loading(Request, blocking: Bool)
        case settled
    }

    private var state: State

    var isBlocking: Bool {
        switch state {
        case let .idle(blocking), let .loading(_, blocking): blocking
        case .settled: false
        }
    }

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    init(isBlocking: Bool = false) {
        state = .idle(blocking: isBlocking)
    }

    mutating func begin() -> Request {
        let request = Request()
        state = .loading(request, blocking: isBlocking)
        return request
    }

    func owns(_ request: Request) -> Bool {
        guard case let .loading(active, _) = state else { return false }
        return active == request
    }

    @discardableResult
    mutating func finish(_ request: Request) -> Bool {
        guard owns(request) else { return false }
        state = .settled
        return true
    }

    mutating func invalidate() {
        state = .idle(blocking: isBlocking)
    }
}
