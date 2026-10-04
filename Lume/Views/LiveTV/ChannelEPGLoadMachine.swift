import Foundation

/// Owns incremental now/next snapshots, not channel pagination or focus.
/// Empty guide answers count as looked up; scope changes and stale requests
/// cannot reuse or publish another list's snapshot.
nonisolated struct ChannelEPGLoadMachine {
    /// Which list this is. A change hides the old pairs at once: they belong
    /// to another playlist, profile or section.
    struct Scope: Hashable {
        let playlistPrefix: String
        let visibilityToken: String
        let channelScope: LiveChannelScope
    }

    /// What can make the same list's pairs out of date: its channels changing
    /// (a favourite added, a channel joining Recents) or a guide sync starting
    /// or ending. A change refetches every visible channel, but keeps the old
    /// pairs on screen until the answer lands.
    struct Refresh: Hashable {
        let channelIDs: Set<String>
        let guideIsSyncing: Bool
    }

    struct Key: Hashable {
        let scope: Scope
        let refresh: Refresh
        let visibleChannelIDs: Set<String>
    }

    struct Request: Equatable {
        fileprivate let token = RequestToken()
        let channelIDs: [String]
        fileprivate let extending: Bool
        fileprivate let startedAt: Date
    }

    private var active: Request?
    private var scope: Scope?
    private var refresh: Refresh?
    private var resolved: [String: ChannelEPG] = [:]
    private var lookedUp: Set<String> = []
    private var resolvedAt = Date.distantPast

    func snapshot(for scope: Scope) -> [String: ChannelEPG] {
        self.scope == scope ? resolved : [:]
    }

    mutating func begin(_ key: Key, now: Date = Date()) -> Request? {
        active = nil
        let refreshed = scope == key.scope && refresh != key.refresh
        if scope != key.scope {
            resolved = [:]
            lookedUp = []
            resolvedAt = .distantPast
        }
        scope = key.scope
        refresh = key.refresh
        let channelIDs = key.visibleChannelIDs.filter { !$0.isEmpty }
        guard !channelIDs.isEmpty else {
            resolved = [:]
            lookedUp = []
            resolvedAt = .distantPast
            return nil
        }
        let age = now.timeIntervalSince(resolvedAt)
        let extending = !refreshed && age >= 0 && age < ChannelEPGLoader.snapshotLifetime
        let pending = extending ? channelIDs.subtracting(lookedUp) : channelIDs
        guard !pending.isEmpty else { return nil }
        let request = Request(channelIDs: pending.sorted(), extending: extending, startedAt: now)
        active = request
        return request
    }

    @discardableResult
    mutating func finish(_ request: Request, with answer: [String: ChannelEPG]) -> Bool {
        guard active == request else { return false }
        if request.extending {
            resolved.merge(answer) { _, fresh in fresh }
            lookedUp.formUnion(request.channelIDs)
        } else {
            resolved = answer
            lookedUp = Set(request.channelIDs)
            resolvedAt = request.startedAt
        }
        active = nil
        return true
    }

    mutating func cancel(_ request: Request) {
        if active == request { active = nil }
    }
}
