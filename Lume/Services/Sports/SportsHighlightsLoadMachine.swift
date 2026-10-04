//
//  SportsHighlightsLoadMachine.swift
//  Lume
//
//  Presentation state for the optional, wider-than-follows "Big this week"
//  feed. The feed is useful while it is being refreshed, so loading retains the
//  last result instead of blanking a rail that has already appeared.
//

nonisolated struct SportsHighlightsLoadMachine: Equatable {
    typealias Result = SportsHighlightsPipeline.Result

    struct Request: Equatable {
        fileprivate let token = RequestToken()
    }

    private enum State: Equatable {
        case idle
        case loading(Request, Result?)
        case content(Result)
    }

    private var state: State = .idle
    private var visibilityToken: String?

    /// A previous visibility scope must not supply channels or PPV actions
    /// while the replacement task is waiting to start.
    func result(for visibilityToken: String) -> Result {
        self.visibilityToken == visibilityToken ? result : Result(highlights: [], resolved: [:])
    }

    var result: Result {
        switch state {
        case .idle:
            Result(highlights: [], resolved: [:])
        case let .loading(_, previous):
            previous ?? Result(highlights: [], resolved: [:])
        case let .content(result):
            result
        }
    }

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    /// Starts a new request. A fresh identity intentionally replaces an older
    /// in-flight request: a profile/follow change must not wait for stale work.
    mutating func begin(visibilityToken: String = "") -> Request {
        let request = Request()
        let previous = self.visibilityToken == visibilityToken ? result : nil
        self.visibilityToken = visibilityToken
        state = .loading(request, previous)
        return request
    }

    /// Applies only the current request, making a result that survived task
    /// cancellation harmless.
    @discardableResult
    mutating func finish(_ request: Request, result: Result) -> Bool {
        guard case let .loading(active, _) = state, active == request else { return false }
        state = .content(result)
        return true
    }
}
