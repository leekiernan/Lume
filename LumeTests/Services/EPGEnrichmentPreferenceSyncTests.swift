import Foundation
@testable import Lume
import Testing

struct EPGEnrichmentPreferenceSyncTests {
    @Test func `explicit off is meaningful user state and round trips through a shadow baseline`() throws {
        var value = ContentStateValues(watchProgress: 0, isWatched: false, lastWatchedDate: nil,
                                       isFavorite: false, addedToWatchlistDate: nil, favoriteOrder: nil)
        #expect(value.isEmpty)
        value.epgEnrichmentEnabled = false
        #expect(!value.isEmpty)
        let decoded = try JSONDecoder().decode(ContentStateValues.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
        #expect(decoded.epgEnrichmentEnabled == false)
    }

    @Test func `legacy shadows inherit defaults rather than silently opting in`() throws {
        let data = Data(#"{"watchProgress":0,"isWatched":false,"isFavorite":false}"#.utf8)
        let decoded = try JSONDecoder().decode(ContentStateValues.self, from: data)
        #expect(decoded.epgEnrichmentEnabled == nil)
        #expect(decoded.isEmpty)
    }

    @Test func `ordinary edits propagate and only simultaneous conflicts prefer off`() {
        let off = ContentStateValues(watchProgress: 0, isWatched: false, lastWatchedDate: nil,
                                     isFavorite: false, addedToWatchlistDate: nil, favoriteOrder: nil, epgEnrichmentEnabled: false)
        var enabled = off
        enabled.epgEnrichmentEnabled = true
        #expect(CloudSyncMerge.reconcile(local: enabled, cloud: off, shadow: off, mergeConflict: ContentStateValues.mergeConflict) == .pushToCloud(enabled))
        #expect(CloudSyncMerge.reconcile(local: off, cloud: enabled, shadow: off, mergeConflict: ContentStateValues.mergeConflict) == .pullToLocal(enabled))
        #expect(ContentStateValues.mergeConflict(local: off, cloud: enabled).epgEnrichmentEnabled == false)
        #expect(ContentStateValues.mergeConflict(local: enabled, cloud: off).epgEnrichmentEnabled == false)
    }
}
