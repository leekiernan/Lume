@testable import Lume
import Testing

@MainActor
struct TrackerIntegrationPresentationTests {
    @Test func `device code presentation keeps provider destinations distinct`() {
        #expect(TrackerIntegrationPresentation.trakt.activationAddress == "trakt.tv/activate")
        #expect(TrackerIntegrationPresentation.simkl.activationAddress == "simkl.com/pin")
    }

    @Test func `in progress imports count only for providers supporting them`() {
        let trakt = TrackerImportStatus(provider: .trakt, movies: 0, episodes: 0, queuedShows: 0, inProgress: 2, failed: false)
        let simkl = TrackerImportStatus(provider: .simkl, movies: 0, episodes: 0, queuedShows: 0, inProgress: 2, failed: false)
        #expect(!trakt.markedNothing)
        #expect(simkl.markedNothing)
    }

    @Test func `queued shows count as imported work for both trackers`() {
        for provider in TrackerIntegrationPresentation.allCases {
            let status = TrackerImportStatus(provider: provider, movies: 0, episodes: 0, queuedShows: 1, failed: false)
            #expect(!status.markedNothing)
        }
    }

    @Test func `a failed import is not an empty successful history`() {
        for provider in TrackerIntegrationPresentation.allCases {
            let status = TrackerImportStatus(provider: provider, movies: 0, episodes: 0, queuedShows: 0, failed: true)
            #expect(!status.markedNothing)
        }
    }
}
