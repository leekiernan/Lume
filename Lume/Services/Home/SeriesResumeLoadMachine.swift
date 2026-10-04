import Foundation
import Observation
import SwiftData

/// The observed window is deliberately caller-owned: Home observes its bounded
/// watch rail; Series needs only its newest watch stamp. Neither scans episodes
/// from a view body or expands its query just to build a task identifier.
nonisolated struct SeriesResumeLoadKey: Hashable {
    struct Scope: Hashable {
        let playlistPrefix: String?
        let visibility: String
        let profileID: UUID?
    }

    struct WatchStamp: Hashable {
        let id: String
        let watchedAt: Date?
    }

    let scope: Scope
    let watched: [WatchStamp]

    @MainActor init(playlistPrefix: String?, restriction: ContentRestriction, watched: [Series], profileID: UUID? = ActiveProfileStore.current) {
        scope = Scope(playlistPrefix: playlistPrefix, visibility: restriction.visibilityToken, profileID: profileID)
        self.watched = watched.map { WatchStamp(id: $0.id, watchedAt: $0.lastWatchedDate) }
    }
}

/// Presentation publication only. The indexed episode lookup and optional
/// bounded watch-rail split retain their own fetching/context ownership.
@Observable
final class SeriesResumeLoadMachine {
    struct Snapshot {
        var fractions: [String: Double] = [:]
        var progress = ContinueWatchingLoader.Result()
    }

    private struct Request: Equatable {
        let id = RequestToken()
        let key: SeriesResumeLoadKey
    }

    private enum State {
        case idle
        case loading(Request)
        case loaded(Request)
    }

    private var state = State.idle
    private var publishedScope: SeriesResumeLoadKey.Scope?
    private var published = Snapshot()
    private let lookup: @Sendable (ModelContainer) async -> [String: Double]

    init(lookup: @escaping @Sendable (ModelContainer) async -> [String: Double] = SeriesResumeLoader.loadAsync) {
        self.lookup = lookup
    }

    /// Reject another profile/playlist/visibility scope even before its task
    /// runs. Same-scope refreshes retain the last complete snapshot.
    func snapshot(for key: SeriesResumeLoadKey) -> Snapshot {
        publishedScope == key.scope ? published : Snapshot()
    }

    func load(
        for key: SeriesResumeLoadKey,
        in container: ModelContainer,
        progress: (() async -> ContinueWatchingLoader.Result)? = nil
    ) async {
        guard !Task.isCancelled else { return }
        let request = Request(key: key)
        state = .loading(request)
        defer {
            if owns(request) { state = .idle }
        }
        let fractions = await lookup(container)
        guard !Task.isCancelled, owns(request) else { return }
        let split = await progress?() ?? ContinueWatchingLoader.Result()
        guard !Task.isCancelled, owns(request) else { return }
        published = Snapshot(fractions: fractions, progress: split)
        publishedScope = key.scope
        state = .loaded(request)
    }

    func invalidate() {
        state = .idle
    }

    private func owns(_ request: Request) -> Bool {
        guard case let .loading(active) = state else { return false }
        return active == request
    }
}
