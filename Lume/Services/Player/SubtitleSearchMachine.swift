import Foundation

nonisolated enum SubtitleSearchStatus: Equatable {
    case searching
    case failed(String)
    case unsupported
    case empty
    case results
}

/// Search and download have separate ownership: a language refresh must not
/// spend a second download or invalidate a file the viewer already selected.
nonisolated struct SubtitleSearchMachine {
    struct Request: Equatable {
        fileprivate let token = RequestToken()
    }

    private enum SearchState {
        case idle
        case loading(Request)
        case loaded
        case unsupported
        case failed(String)
    }

    private var state: SearchState = .idle
    private enum DownloadState {
        case idle
        case downloading(Request, subtitleID: String)
        case failed(String)
    }

    private var downloadState: DownloadState = .idle
    private var mediaID: String?
    private(set) var results: [OnlineSubtitle] = []
    var downloadingID: String? {
        if case let .downloading(_, id) = downloadState { return id }
        return nil
    }

    var downloadError: String? {
        if case let .failed(message) = downloadState { return message }
        return nil
    }

    var isSearching: Bool {
        if case .loading = state { return true }
        return false
    }

    var status: SubtitleSearchStatus {
        switch state {
        case .idle, .loading:
            results.isEmpty ? .searching : .results
        case .unsupported:
            .unsupported
        case let .failed(message):
            .failed(message)
        case .loaded:
            results.isEmpty ? .empty : .results
        }
    }

    mutating func begin(mediaID: String, supported: Bool) -> Request {
        if self.mediaID != mediaID {
            invalidate()
            results = []
        }
        self.mediaID = mediaID
        let request = Request()
        state = supported ? .loading(request) : .unsupported
        if !supported { results = [] }
        return request
    }

    @discardableResult
    mutating func finish(_ request: Request, results: [OnlineSubtitle]) -> Bool {
        guard case let .loading(active) = state, active == request else { return false }
        self.results = results
        state = .loaded
        return true
    }

    @discardableResult
    mutating func fail(_ request: Request, message: String) -> Bool {
        guard case let .loading(active) = state, active == request else { return false }
        state = .failed(message)
        return true
    }

    mutating func beginDownload(_ subtitle: OnlineSubtitle) -> Request? {
        guard downloadingID == nil else { return nil }
        let request = Request()
        downloadState = .downloading(request, subtitleID: subtitle.id)
        return request
    }

    @discardableResult
    mutating func finishDownload(_ request: Request, error: String? = nil) -> Bool {
        guard case let .downloading(active, _) = downloadState, active == request else { return false }
        downloadState = if let error { .failed(error) } else { .idle }
        return true
    }

    /// Dismissal rejects late success, error, and download presentation callbacks.
    mutating func invalidate() {
        state = .idle
        downloadState = .idle
    }
}
