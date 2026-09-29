/// Owns the cursor and in-flight ownership contract for an incremental
/// collection. The caller retains its visible items and fetching details; this
/// type only decides whether a page may start and whether a returned page still
/// belongs to the active result set.
///
/// A request carries the generation and source offset it started from. Resetting
/// for new query inputs advances that generation, so a detached fetch from the
/// old query cannot append into the replacement grid.
struct PaginationMachine: Equatable {
    struct Request: Equatable, Hashable {
        fileprivate let generation: UInt
        let offset: Int
    }

    private enum State: Equatable {
        case idle
        case ready
        case loading(Request)
        case exhausted
    }

    private(set) var key: String?
    private(set) var nextOffset = 0
    private var generation: UInt = 0
    private var state: State = .idle

    var isPrepared: Bool {
        key != nil
    }

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    /// True while the current result set may produce another source page. It
    /// intentionally remains true during an active request so loading spinners
    /// can remain attached to the trailing item.
    var canLoadMore: Bool {
        switch state {
        case .ready, .loading: true
        case .idle, .exhausted: false
        }
    }

    /// Starts a distinct result set. Reusing the same key preserves loaded rows
    /// and scroll position when a view reappears.
    @discardableResult
    mutating func prepare(for key: String) -> Bool {
        guard self.key != key else { return false }
        self.key = key
        restart()
        return true
    }

    /// Throws away the current window while retaining its query identity. Used
    /// after an explicit data refresh for the same category.
    @discardableResult
    mutating func restart() -> Bool {
        guard key != nil else { return false }
        generation &+= 1
        nextOffset = 0
        state = .ready
        return true
    }

    /// Seeds the machine from an already hydrated window, such as a section
    /// feed's cached preview. This never changes request generation because no
    /// request can be active immediately after `prepare(for:)`.
    mutating func seed(nextOffset: Int, canLoadMore: Bool) {
        guard key != nil else { return }
        self.nextOffset = max(0, nextOffset)
        state = canLoadMore ? .ready : .exhausted
    }

    /// Starts the sole page allowed for the current result set.
    mutating func beginLoading() -> Request? {
        guard case .ready = state else { return nil }
        let request = Request(generation: generation, offset: nextOffset)
        state = .loading(request)
        return request
    }

    /// Commits a page only when it is still the active request. `scanned` is a
    /// source-row count rather than a visible-item count: duplicate-collapse and
    /// post-fetch filtering must not make the cursor revisit rows forever.
    @discardableResult
    mutating func finish(_ request: Request, scanned: Int, hasMore: Bool) -> Bool {
        guard state == .loading(request) else { return false }
        nextOffset += max(0, scanned)
        state = hasMore ? .ready : .exhausted
        return true
    }

    /// Releases the active request after a fetch error or task cancellation,
    /// preserving the cursor so a later appearance can retry it.
    @discardableResult
    mutating func abandon(_ request: Request) -> Bool {
        guard state == .loading(request) else { return false }
        state = .ready
        return true
    }

    /// Replaces the already-visible source window after a background refresh.
    /// Any older in-flight page becomes stale before the new cursor is exposed.
    mutating func replaceWindow(scanned: Int, hasMore: Bool) {
        guard key != nil else { return }
        generation &+= 1
        nextOffset = max(0, scanned)
        state = hasMore ? .ready : .exhausted
    }
}
