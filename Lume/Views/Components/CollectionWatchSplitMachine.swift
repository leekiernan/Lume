import Foundation

/// A watch split may append pages itself. Those appends must not cancel the
/// task doing the drain; scope changes or edits to existing watch stamps must.
/// Episode loading and pagination stay in their existing owners.
nonisolated struct CollectionWatchSplitMachine {
    struct Request: Equatable {
        let id = RequestToken()
        let key: [String]
    }

    private(set) var taskKey: [String] = []
    private var active: Request?
    private var settledKey: [String]?

    mutating func update(for key: [String]) {
        guard key != taskKey else { return }
        if active == nil, key == settledKey { return }
        if let active, key.starts(with: active.key) { return }
        active = nil
        settledKey = nil
        taskKey = key
    }

    mutating func begin() -> Request {
        let request = Request(key: taskKey)
        active = request
        return request
    }

    @discardableResult
    mutating func finish(_ request: Request, publishedKey: [String]? = nil) -> Bool {
        guard active == request else { return false }
        active = nil
        settledKey = publishedKey
        return true
    }
}
