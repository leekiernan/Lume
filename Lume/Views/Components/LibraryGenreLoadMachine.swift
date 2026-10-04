import Foundation
import Observation

struct LibraryGenreLoadKey: Hashable {
    let prefix: String
    let visibility: String
    let profile: UUID?
    let syncedAt: Date?
}

/// The sidebar's derived genre list has its own publication owner. It is not
/// a paged grid and never takes over a provider import or SectionFeed task.
@Observable
final class LibraryGenreLoadMachine {
    private var publishedKey: LibraryGenreLoadKey?
    private var values: [String] = []
    @ObservationIgnored private var owner = UUID()

    func snapshot(for key: LibraryGenreLoadKey) -> [String] {
        publishedKey == key ? values : []
    }

    func load(for key: LibraryGenreLoadKey, fetch: () async -> [String]) async {
        let token = UUID()
        owner = token
        let result = await fetch()
        guard !Task.isCancelled, owner == token else { return }
        publishedKey = key
        values = result
    }
}
