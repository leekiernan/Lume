//
//  TraktMutationOutbox.swift
//  Lume
//
//  Durable, account-scoped user intent waiting to reach Trakt. Playback
//  lifecycle events deliberately do not belong here: replaying an old "start"
//  or "pause" after relaunch would manufacture a stale Now Watching session.
//

import Foundation

nonisolated struct TraktMutation: Codable, Equatable, Identifiable {
    nonisolated enum Kind: String, Codable, Equatable {
        case history
        case watchlist
    }

    nonisolated enum Target: Codable, Equatable, Hashable {
        case movie(tmdbID: Int)
        case show(tmdbID: Int)
        case episode(showTMDBID: Int, season: Int, episode: Int)
    }

    let id: UUID
    let kind: Kind
    let target: Target
    /// Whether the target should be present in the selected Trakt collection.
    /// For history this means watched; for watchlist it means watchlisted.
    let isPresent: Bool
    let enqueuedAt: Date
    var attemptCount: Int
    var lastAttemptAt: Date?

    init(
        id: UUID = UUID(),
        kind: Kind,
        target: Target,
        isPresent: Bool,
        enqueuedAt: Date = Date(),
        attemptCount: Int = 0,
        lastAttemptAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.target = target
        self.isPresent = isPresent
        self.enqueuedAt = enqueuedAt
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
    }

    /// Decode the history-only v1 shape as well as the generalized shape. This
    /// matters if an app update lands while a failed history mutation is parked.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .history
        target = try container.decode(Target.self, forKey: .target)
        isPresent = try container.decodeIfPresent(Bool.self, forKey: .isPresent)
            ?? container.decode(Bool.self, forKey: .watched)
        enqueuedAt = try container.decode(Date.self, forKey: .enqueuedAt)
        attemptCount = try container.decode(Int.self, forKey: .attemptCount)
        lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(target, forKey: .target)
        try container.encode(isPresent, forKey: .isPresent)
        try container.encode(enqueuedAt, forKey: .enqueuedAt)
        try container.encode(attemptCount, forKey: .attemptCount)
        try container.encodeIfPresent(lastAttemptAt, forKey: .lastAttemptAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, target, isPresent, watched, enqueuedAt, attemptCount, lastAttemptAt
    }
}

nonisolated struct TraktMutationStatus: Equatable {
    let pendingCount: Int
    let failedCount: Int

    static let empty = TraktMutationStatus(pendingCount: 0, failedCount: 0)
}

/// Small JSON outbox in UserDefaults. Mutations are ordered oldest-first and
/// partitioned by stable Trakt account scope so signing into another account
/// can never replay the previous account's intent. Enqueuing the same kind and
/// target again removes the older value and appends the latest intent to the
/// tail. History and watchlist intent for one title remain independent.
@MainActor
final class TraktMutationOutbox {
    private struct State: Codable {
        var accounts: [String: [TraktMutation]] = [:]
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
        kind: TraktMutation.Kind,
        target: TraktMutation.Target,
        isPresent: Bool,
        account: String,
        now: Date = Date()
    ) -> TraktMutation {
        let account = Self.normalize(account)
        var mutations = state.accounts[account] ?? []
        mutations.removeAll { $0.kind == kind && $0.target == target }
        let mutation = TraktMutation(
            kind: kind,
            target: target,
            isPresent: isPresent,
            enqueuedAt: now
        )
        mutations.append(mutation)
        state.accounts[account] = mutations
        persist()
        return mutation
    }

    func firstMutation(account: String) -> TraktMutation? {
        state.accounts[Self.normalize(account)]?.first
    }

    func mutations(account: String) -> [TraktMutation] {
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
        mutation: (inout [TraktMutation]) -> Void
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
