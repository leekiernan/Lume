import Foundation

/// Owns incremental now/next snapshots, not channel pagination or focus.
/// Empty guide answers count as looked up; scope changes and stale requests
/// cannot reuse or publish another list's snapshot.
nonisolated struct ChannelEPGLoadMachine {
    struct Scope: Hashable {
        let playlistPrefix: String
        let visibilityToken: String
        let channelScope: LiveChannelScope
        let channelIDs: Set<String>
        let guideIsSyncing: Bool
    }

    struct Key: Hashable {
        let scope: Scope
        let visibleChannelIDs: Set<String>
    }

    struct Request: Equatable {
        fileprivate let generation: UInt
        let channelIDs: [String]
        fileprivate let extending: Bool
        fileprivate let startedAt: Date
    }

    private var generation: UInt = 0
    private var active: Request?
    private var scope: Scope?
    private var resolved: [String: ChannelEPG] = [:]
    private var lookedUp: Set<String> = []
    private var resolvedAt = Date.distantPast

    func snapshot(for scope: Scope) -> [String: ChannelEPG] {
        self.scope == scope ? resolved : [:]
    }

    mutating func begin(_ key: Key, now: Date = Date()) -> Request? {
        generation &+= 1
        active = nil
        if scope != key.scope {
            resolved = [:]
            lookedUp = []
            resolvedAt = .distantPast
        }
        scope = key.scope
        let channelIDs = key.visibleChannelIDs.filter { !$0.isEmpty }
        guard !channelIDs.isEmpty else {
            resolved = [:]
            lookedUp = []
            resolvedAt = .distantPast
            return nil
        }
        let age = now.timeIntervalSince(resolvedAt)
        let extending = age >= 0 && age < ChannelEPGLoader.snapshotLifetime
        let pending = extending ? channelIDs.subtracting(lookedUp) : channelIDs
        guard !pending.isEmpty else { return nil }
        let request = Request(generation: generation, channelIDs: pending.sorted(), extending: extending, startedAt: now)
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
