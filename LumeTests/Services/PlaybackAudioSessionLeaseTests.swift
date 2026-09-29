import Foundation
@testable import Lume
import Testing

struct PlaybackAudioSessionLeaseTests {
    @Test func `only the current player can release the audio session`() {
        let first = UUID()
        let second = UUID()
        var lease = PlaybackAudioSessionLease()

        let firstClaim = lease.claim(first)
        let secondClaim = lease.claim(second)
        let staleRelease = lease.release(first)
        #expect(firstClaim)
        #expect(secondClaim)
        #expect(!staleRelease)
        #expect(lease.activeOwner == second)
        let currentRelease = lease.release(second)
        #expect(currentRelease)
        #expect(lease.activeOwner == nil)
    }

    @Test func `repeated activation by the same player does not reconfigure audio`() {
        let owner = UUID()
        var lease = PlaybackAudioSessionLease()

        let firstClaim = lease.claim(owner)
        let repeatedClaim = lease.claim(owner)
        #expect(firstClaim)
        #expect(!repeatedClaim)
    }
}
