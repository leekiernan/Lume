//
//  TraktMutationOutbox.swift
//  Lume
//
//  Durable, account-scoped user intent waiting to reach Trakt. Playback
//  lifecycle events deliberately do not belong here: replaying an old "start"
//  or "pause" after relaunch would manufacture a stale Now Watching session.
//

import Foundation

nonisolated struct TraktHistoryMutation: Codable, Equatable, Identifiable {
    nonisolated enum Target: Codable, Equatable, Hashable {
        case movie(tmdbID: Int)
        case episode(showTMDBID: Int, season: Int, episode: Int)
    }

    let id: UUID
    let target: Target
    let watched: Bool
    let enqueuedAt: Date
    var attemptCount: Int
    var lastAttemptAt: Date?

    init(
        id: UUID = UUID(),
        target: Target,
        watched: Bool,
        enqueuedAt: Date = Date(),
        attemptCount: Int = 0,
        lastAttemptAt: Date? = nil
    ) {
        self.id = id
        self.target = target
        self.watched = watched
        self.enqueuedAt = enqueuedAt
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
    }
}

nonisolated struct TraktMutationStatus: Equatable {
    let pendingCount: Int
    let failedCount: Int

    static let empty = TraktMutationStatus(pendingCount: 0, failedCount: 0)
}

/// Small JSON outbox in UserDefaults. Mutations are ordered oldest-first and
/// partitioned by normalized Trakt username so signing into another account can
/// never replay the previous account's intent. Enqueuing the same target again
/// removes the older value and appends the latest intent to the tail.
@MainActor
final class TraktMutationOutbox {
    private struct State: Codable {
        var accounts: [String: [TraktHistoryMutation]] = [:]
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private var state: State

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "trakt.mutationOutbox.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(State.self, from: data)
        {
            state = decoded
        } else {
            state = State()
        }
    }

    @discardableResult
    func enqueue(
        target: TraktHistoryMutation.Target,
        watched: Bool,
        account: String,
        now: Date = Date()
    ) -> TraktHistoryMutation {
        let account = Self.normalize(account)
        var mutations = state.accounts[account] ?? []
        mutations.removeAll { $0.target == target }
        let mutation = TraktHistoryMutation(target: target, watched: watched, enqueuedAt: now)
        mutations.append(mutation)
        state.accounts[account] = mutations
        persist()
        return mutation
    }

    func firstMutation(account: String) -> TraktHistoryMutation? {
        state.accounts[Self.normalize(account)]?.first
    }

    func mutations(account: String) -> [TraktHistoryMutation] {
        state.accounts[Self.normalize(account)] ?? []
    }

    func contains(id: UUID, account: String) -> Bool {
        state.accounts[Self.normalize(account)]?.contains { $0.id == id } == true
    }

    /// Removes only the exact mutation that was sent. If the viewer changed the
    /// same item again while the request was in flight, its replacement has a
    /// different id and remains queued.
    func acknowledge(id: UUID, account: String) {
        mutateAccount(account) { mutations in
            mutations.removeAll { $0.id == id }
        }
    }

    func recordFailure(id: UUID, account: String, now: Date = Date()) {
        mutateAccount(account) { mutations in
            guard let index = mutations.firstIndex(where: { $0.id == id }) else { return }
            mutations[index].attemptCount += 1
            mutations[index].lastAttemptAt = now
        }
    }

    func status(account: String) -> TraktMutationStatus {
        let mutations = state.accounts[Self.normalize(account)] ?? []
        return TraktMutationStatus(
            pendingCount: mutations.count,
            failedCount: mutations.count(where: { $0.attemptCount > 0 })
        )
    }

    private func mutateAccount(
        _ account: String,
        mutation: (inout [TraktHistoryMutation]) -> Void
    ) {
        let account = Self.normalize(account)
        var mutations = state.accounts[account] ?? []
        mutation(&mutations)
        if mutations.isEmpty {
            state.accounts[account] = nil
        } else {
            state.accounts[account] = mutations
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func normalize(_ account: String) -> String {
        account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

nonisolated struct TraktAccountIdentity: Codable, Equatable {
    let username: String
    /// Stable Trakt numeric user id where available; normalized username is a
    /// fallback for older or unusually sparse settings responses.
    let scope: String
}

/// The account identity is not secret. Remembering it alongside the keychain
/// token lets the app keep queueing account-scoped intent during an offline cold
/// launch; the next successful `/users/settings` response refreshes it.
nonisolated enum TraktAccountIdentityStore {
    private static let key = "trakt.lastAccountIdentity.v1"

    static func load(defaults: UserDefaults = .standard) -> TraktAccountIdentity? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(TraktAccountIdentity.self, from: data)
    }

    static func save(_ identity: TraktAccountIdentity, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(identity) else { return }
        defaults.set(data, forKey: key)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
