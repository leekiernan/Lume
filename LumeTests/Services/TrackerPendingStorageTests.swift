import Foundation
@testable import Lume
import Testing

struct TrackerPendingStorageTests {
    @Test func `parked remote history uses platform appropriate storage`() {
        #if os(tvOS)
            #expect(TrackerPendingStorage.directoryKind == .cachesDirectory)
        #else
            #expect(TrackerPendingStorage.directoryKind == .applicationSupportDirectory)
        #endif
        #expect(TrackerPendingStorage.directory == FileManager.default.urls(
            for: TrackerPendingStorage.directoryKind, in: .userDomainMask
        ).first)
    }
}
