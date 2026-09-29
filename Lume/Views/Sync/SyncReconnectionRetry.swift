//
//  SyncReconnectionRetry.swift
//  Lume
//
//  Retries a failed playlist sync when iCloud brings new connection details
//  for it. Split from SyncProgressView.swift to keep it within the length cap.
//

import SwiftUI

extension View {
    /// Re-runs a failed sync once a reconcile pulls new connection details for
    /// its playlist — most often a launch sync that raced the CloudKit import
    /// carrying an address edited on another device, which otherwise sat on
    /// "Sync failed" until the viewer tapped Try Again.
    func retryingSync(of playlistID: UUID, failed: Bool, retry: @escaping () -> Void) -> some View {
        modifier(SyncReconnectionRetry(playlistID: playlistID, failed: failed, retry: retry))
    }
}

private struct SyncReconnectionRetry: ViewModifier {
    let playlistID: UUID
    let failed: Bool
    let retry: () -> Void

    @Environment(CloudSyncCoordinator.self) private var cloudSync: CloudSyncCoordinator?

    func body(content: Content) -> some View {
        content.onChange(of: cloudSync?.status.lastPlaylistReconnection) { _, reconnection in
            guard failed, reconnection?.ids.contains(playlistID) == true else { return }
            retry()
        }
    }
}
