//
//  PendingStoreIsolation.swift
//  LumeTests
//
//  Keeps the tracker imports' parked-progress files away from the installed
//  app's. `TraktPendingWatchedStore` and `SimklPendingWatchedStore` keep a JSON
//  file in Application Support, and the tests run inside the real Lume.app —
//  so a suite resetting "the store" deleted the viewer's own parked Trakt
//  progress. Installed from the bundle's load-time constructor, alongside the
//  credential backend (`CredentialIsolation.c`), before any test can run.
//

import Foundation
@testable import Lume

nonisolated enum PendingStoreIsolation {
    static func install() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumeTests-PendingStores-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        TraktPendingWatchedStore.directory = directory
        SimklPendingWatchedStore.directory = directory
    }
}
