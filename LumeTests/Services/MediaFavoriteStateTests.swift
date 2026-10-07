import Foundation
@testable import Lume
import Testing

struct MediaFavoriteStateTests {
    @Test(arguments: 0 ..< 8)
    func `one heart combines all three lists`(bits: Int) {
        let local = bits & 1 != 0
        let trakt = bits & 2 != 0
        let simkl = bits & 4 != 0
        let state = MediaFavoriteState(local: local, trakt: trakt, simkl: simkl)
        let present = local || trakt || simkl
        #expect(state.isFavorite == present)
        #expect(state.toggled == !present)
        #expect(state.traktIntent == (!present || trakt ? !present : nil))
        #expect(state.simklIntent == (!present || simkl ? !present : nil))
    }

    @Test func `disconnected trackers receive no intent`() {
        for local in [false, true] {
            let state = MediaFavoriteState(local: local, trakt: nil, simkl: nil)
            #expect(state.isFavorite == local)
            #expect(state.traktIntent == nil)
            #expect(state.simklIntent == nil)
        }
    }
}

@MainActor
struct TrackerWatchlistMembershipTests {
    private let movie = TrackerMutation.Target.movie(tmdbID: 1)

    @Test func `a new tap rejects an older snapshot`() {
        let state = TrackerWatchlistMembership()
        state.reset(account: "alice")
        let revision = state.revision
        state.apply(movie, isPresent: true)
        state.replace(with: [], account: "alice", revision: revision)
        #expect(state.contains(movie, account: "alice"))
    }

    @Test func `acknowledgement rejects a read begun before delivery`() {
        let state = TrackerWatchlistMembership()
        state.reset(account: "alice")
        state.apply(movie, isPresent: true)
        let revision = state.revision
        state.invalidate()
        state.replace(with: [], account: "alice", revision: revision)
        #expect(state.contains(movie, account: "alice"))
    }

    @Test func `accounts and reconnects cannot inherit a snapshot`() {
        let state = TrackerWatchlistMembership()
        state.reset(account: "alice")
        let revision = state.revision
        state.apply(movie, isPresent: true)
        #expect(!state.contains(movie, account: "bob"))
        state.reset(account: nil)
        state.reset(account: "alice")
        state.replace(with: [movie], account: "alice", revision: revision)
        #expect(!state.contains(movie, account: "alice"))
        #expect(state.needsRefresh)
    }

    @Test func `a fresh full snapshot accepts unmatched titles and distinguishes movie from show`() {
        let state = TrackerWatchlistMembership()
        state.reset(account: "alice")
        state.replace(with: [movie], account: "alice", revision: state.revision)
        #expect(state.contains(movie, account: "alice"))
        #expect(!state.contains(.show(tmdbID: 1), account: "alice"))
        #expect(!state.needsRefresh)
    }
}
