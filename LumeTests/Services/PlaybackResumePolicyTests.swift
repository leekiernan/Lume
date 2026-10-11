@testable import Lume
import Testing

struct PlaybackResumePolicyTests {
    @Test(arguments: [0.0, 0.1, 59.9])
    func `only positions strictly below one percent are discarded`(position: Double) {
        #expect(PlaybackResumePolicy.discardsProgress(position: position, duration: 6000))
    }

    @Test(arguments: [60.0, 61, 6000])
    func `one percent and later positions are retained`(position: Double) {
        #expect(!PlaybackResumePolicy.discardsProgress(position: position, duration: 6000))
    }

    @Test func `unknown and invalid clocks cannot clear progress`() {
        #expect(!PlaybackResumePolicy.discardsProgress(position: 1, duration: 0))
        #expect(!PlaybackResumePolicy.discardsProgress(position: 1, duration: -1))
        #expect(!PlaybackResumePolicy.discardsProgress(position: -1, duration: 6000))
        #expect(!PlaybackResumePolicy.discardsProgress(position: .nan, duration: 6000))
        #expect(!PlaybackResumePolicy.discardsProgress(position: 1, duration: .infinity))
    }
}
