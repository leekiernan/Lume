@testable import Lume
import Testing

struct MediaFavoriteDestinationTests {
    @Test(arguments: 0 ..< 8, MediaFavoriteState.Destination.allCases)
    func `individual changes affect only the selected destination`(bits: Int, destination: MediaFavoriteState.Destination) throws {
        let state = MediaFavoriteState(local: bits & 1 != 0, trakt: bits & 2 != 0, simkl: bits & 4 != 0)
        for isPresent in [false, true] {
            let change = try #require(state.change(setting: isPresent, in: destination))
            #expect(change.local == (destination == .local ? isPresent : nil))
            #expect(change.trakt == (destination == .trakt ? isPresent : nil))
            #expect(change.simkl == (destination == .simkl ? isPresent : nil))
        }
    }

    @Test func `unavailable services cannot be changed`() {
        let state = MediaFavoriteState(local: true, trakt: nil, simkl: nil)
        for isPresent in [false, true] {
            #expect(state.change(setting: isPresent, in: .trakt) == nil)
            #expect(state.change(setting: isPresent, in: .simkl) == nil)
            #expect(state.change(setting: isPresent, in: .local) == .init(local: isPresent))
        }
    }

    @Test(arguments: 0 ..< 8)
    func `normal press still synchronizes the combined membership`(bits: Int) {
        let state = MediaFavoriteState(local: bits & 1 != 0, trakt: bits & 2 != 0, simkl: bits & 4 != 0)
        let change = state.toggleChange
        let present = state.isFavorite
        #expect(change.local == !present)
        #expect(change.trakt == (!present || state.trakt == true ? !present : nil))
        #expect(change.simkl == (!present || state.simkl == true ? !present : nil))
    }

    @Test func `one remaining remote membership keeps the heart filled`() {
        #expect(MediaFavoriteState(local: false, trakt: true, simkl: false).isFavorite)
        #expect(MediaFavoriteState(local: false, trakt: false, simkl: true).isFavorite)
        #expect(!MediaFavoriteState(local: false, trakt: false, simkl: false).isFavorite)
    }
}
