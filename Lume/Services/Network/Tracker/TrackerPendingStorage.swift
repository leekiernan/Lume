import Foundation

/// Device-local copies of remote history, rebuilt by the next tracker import.
/// tvOS only permits purgeable file storage; other platforms keep their
/// existing location so already parked progress remains readable.
nonisolated enum TrackerPendingStorage {
    static var directoryKind: FileManager.SearchPathDirectory {
        #if os(tvOS)
            .cachesDirectory
        #else
            .applicationSupportDirectory
        #endif
    }

    static var directory: URL? {
        FileManager.default.urls(for: directoryKind, in: .userDomainMask).first
    }
}
