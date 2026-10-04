import Foundation
import Observation

struct LibraryGenreLoadKey: Hashable {
    let prefix: String
    let visibility: String
    let profile: UUID?
    /// Re-derives the list after a sync, but isn't part of its identity: the
    /// same playlist, visibility and profile keep showing their genres while
    /// the refresh runs, rather than emptying the sidebar after every sync.
    let syncedAt: Date?

    fileprivate var identity: [AnyHashable] {
        [prefix, visibility, profile]
    }
}

/// The sidebar's derived genre list has its own publication owner. It is not
/// a paged grid and never takes over a provider import or SectionFeed task.
@Observable
final class LibraryGenreLoadMachine {
    private var publishedKey: LibraryGenreLoadKey?
    private var values: [String] = []
    @ObservationIgnored private var owner = RequestToken()

    func snapshot(for key: LibraryGenreLoadKey) -> [String] {
        publishedKey?.identity == key.identity ? values : []
    }

    func load(for key: LibraryGenreLoadKey, fetch: () async -> [String]) async {
        let token = RequestToken()
        owner = token
        let result = await fetch()
        guard !Task.isCancelled, owner == token else { return }
        publishedKey = key
        values = result
    }
}
