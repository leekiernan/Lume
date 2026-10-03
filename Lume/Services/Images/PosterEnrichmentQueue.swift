import Foundation

nonisolated enum PosterMediaKind: Hashable { case movie, series }

nonisolated struct PosterArtworkRequest: Hashable {
    let kind: PosterMediaKind
    let id: String
    let categoryID: String?
}

nonisolated struct PosterLookupResult {
    let path: String?
    let checkedAt: Date
}

/// Admission and subscriber lifetimes only. No SwiftData objects or view state
/// cross this boundary. A cancelled running job keeps its slot until it exits.
actor PosterEnrichmentQueue {
    static let shared = PosterEnrichmentQueue()

    nonisolated struct Key: Hashable {
        let catalog: ObjectIdentifier
        let request: PosterArtworkRequest
        let profile: UUID?
        let visibility: String
    }

    private enum State { case queued, running(UUID) }
    private struct Entry {
        var state: State
        var subscribers: [UUID: CheckedContinuation<PosterLookupResult?, Never>]
        let operation: @Sendable () async throws -> PosterLookupResult
    }

    private struct Memo {
        let result: PosterLookupResult?
        let expires: Date
    }

    private let limit: Int
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private var running: [UUID: Task<Void, Never>] = [:]
    private var memo: [Key: Memo] = [:]

    init(limit: Int = 2) {
        self.limit = max(1, limit)
    }

    func lookup(_ key: Key, operation: @escaping @Sendable () async throws -> PosterLookupResult) async -> PosterLookupResult? {
        guard !Task.isCancelled else { return nil }
        if let cached = memo[key], cached.expires > .now { return cached.result }
        memo[key] = nil
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                if var entry = entries[key] {
                    entry.subscribers[token] = continuation
                    entries[key] = entry
                } else {
                    entries[key] = Entry(state: .queued, subscribers: [token: continuation], operation: operation)
                    order.append(key)
                }
                pump()
            }
        } onCancel: {
            Task { await self.cancel(key, subscriber: token) }
        }
    }

    private func cancel(_ key: Key, subscriber: UUID) {
        guard var entry = entries[key], let continuation = entry.subscribers.removeValue(forKey: subscriber) else { return }
        continuation.resume(returning: nil)
        if entry.subscribers.isEmpty {
            entries[key] = nil
            order.removeAll { $0 == key }
            if case let .running(id) = entry.state { running[id]?.cancel() }
        } else {
            entries[key] = entry
        }
        pump()
    }

    private func pump() {
        while running.count < limit, !order.isEmpty {
            let key = order.removeFirst()
            guard var entry = entries[key] else { continue }
            let id = UUID()
            entry.state = .running(id)
            entries[key] = entry
            let operation = entry.operation
            running[id] = Task {
                let result: PosterLookupResult?
                do {
                    let candidate = try await operation()
                    try Task.checkCancellation()
                    result = candidate
                } catch { result = nil }
                finish(key, id: id, result: result)
            }
        }
    }

    private func finish(_ key: Key, id: UUID, result: PosterLookupResult?) {
        running[id] = nil
        // A cancelled generation must never retire or publish its replacement.
        if let entry = entries[key], case let .running(current) = entry.state, current == id {
            entries[key] = nil
            let expires = result.map { $0.checkedAt.addingTimeInterval(14 * 24 * 3600) }
                ?? Date.now.addingTimeInterval(60)
            memo[key] = Memo(result: result, expires: expires)
            if memo.count > 256 { memo = memo.filter { $0.value.expires > .now } }
            if memo.count > 256 {
                memo = Dictionary(uniqueKeysWithValues: memo.sorted { $0.value.expires > $1.value.expires }.prefix(128).map { ($0.key, $0.value) })
            }
            for continuation in entry.subscribers.values {
                continuation.resume(returning: result)
            }
        }
        pump()
    }
}
