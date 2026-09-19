import Foundation
@testable import Lume
import SwiftData
import Testing

private nonisolated enum InjectedProfileEngineSaveError: Error {
    case forced
}

@MainActor
@Suite(.serialized)
struct ProfilePersistenceSafetyTests {
    @Test func `failed profile switch keeps the old projection pointer and shadow`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let profileA = UUID()
        let profileB = UUID()
        let movieID = "pl-movie-1"
        let movie = Movie(id: movieID, streamId: 1, name: "Film")
        movie.isFavorite = true
        ctx.insert(movie)
        ctx.insert(UserContentState(
            contentId: movieID,
            kind: .movie,
            profileID: profileB,
            watchProgress: 500,
            isWatched: true
        ))
        try ctx.save()

        let baseline = ContentStateValues(
            watchProgress: 100,
            isWatched: false,
            lastWatchedDate: nil,
            isFavorite: true,
            addedToWatchlistDate: nil,
            favoriteOrder: nil,
            customOrder: nil
        )
        let shadow = freshShadow()
        shadow.setContentShadow(movieID, baseline)
        shadow.persist()

        let saved = ActiveProfileStore.current
        ActiveProfileStore.current = profileA
        defer { ActiveProfileStore.current = saved }

        let engine = CloudSyncEngine(
            container: container,
            shadow: shadow,
            saveFailureInjector: { role in
                if role == .cloud { throw InjectedProfileEngineSaveError.forced }
            }
        )

        await #expect(throws: InjectedProfileEngineSaveError.self) {
            try await engine.switchProfile(from: profileA, to: profileB)
        }

        #expect(ActiveProfileStore.current == profileA)
        #expect(shadow.contentShadow(movieID) == baseline)
        let projected = try #require(ctx.fetch(FetchDescriptor<Movie>()).first)
        #expect(projected.isFavorite)
        #expect(projected.watchProgress == 0)
    }

    private func freshShadow() -> CloudSyncShadow {
        let suite = UserDefaults(suiteName: "profile-persistence.test.\(UUID().uuidString)")!
        return CloudSyncShadow(defaults: suite)
    }
}
