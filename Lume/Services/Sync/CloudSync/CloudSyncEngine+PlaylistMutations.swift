//
//  CloudSyncEngine+PlaylistMutations.swift
//  Lume
//
//  Writing a playlist's merged config to either side. Split from
//  CloudSyncEngine.swift to keep it within the length limit.
//

import Foundation
import SwiftData

extension CloudSyncEngine {
    func applyPlaylistToCloud(_ value: PlaylistConfigValues?, id: UUID, mirror: SyncedPlaylist?) {
        guard let value else {
            if let mirror { cloudContext.delete(mirror) }
            return
        }
        if let mirror {
            mirror.name = value.name
            mirror.serverURL = value.serverURL
            mirror.username = value.username
            mirror.password = value.password
            mirror.macAddress = value.macAddress
            mirror.sourceTypeRaw = value.sourceTypeRaw
            mirror.epgURL = value.epgURL
            mirror.syncEnabled = value.syncEnabled
            mirror.updatedAt = Date()
        } else {
            cloudContext.insert(SyncedPlaylist(
                id: id,
                name: value.name,
                serverURL: value.serverURL,
                username: value.username,
                password: value.password,
                macAddress: value.macAddress,
                sourceTypeRaw: value.sourceTypeRaw,
                epgURL: value.epgURL,
                syncEnabled: value.syncEnabled
            ))
        }
    }

    /// Returns true if a new local `Playlist` was created (it has no
    /// `lastSyncDate`, so the UI's auto-sync will fetch its catalog).
    func applyPlaylistToLocal(_ value: PlaylistConfigValues?, id: UUID, local: Playlist?) -> Bool {
        guard let value else {
            // Mirror the local-deletion path: remove the playlist's orphaned
            // catalog content too, not just the `Playlist` row.
            if let local { PlaylistDeletion.delete(local, in: catalogContext) }
            return false
        }
        if let local {
            local.name = value.name
            local.serverURL = value.serverURL
            local.username = value.username
            local.password = value.password
            local.macAddress = value.macAddress.isEmpty ? nil : value.macAddress
            local.sourceTypeRaw = value.sourceTypeRaw
            local.epgURL = value.epgURL
            local.syncEnabled = value.syncEnabled
            return false
        }
        let playlist = Playlist(name: value.name, serverURL: value.serverURL, username: value.username, password: value.password)
        playlist.id = id
        playlist.macAddress = value.macAddress.isEmpty ? nil : value.macAddress
        playlist.sourceTypeRaw = value.sourceTypeRaw
        playlist.epgURL = value.epgURL
        playlist.syncEnabled = value.syncEnabled
        catalogContext.insert(playlist)
        return true
    }

    func applyEPGSourceToCloud(_ value: EPGSourceValues?, id: UUID, mirror: SyncedEPGSource?) {
        guard let value else {
            if let mirror { cloudContext.delete(mirror) }
            return
        }
        if let mirror {
            mirror.name = value.name
            mirror.url = value.url
            mirror.isEnabled = value.isEnabled
            mirror.updatedAt = Date()
        } else {
            cloudContext.insert(SyncedEPGSource(id: id, name: value.name, url: value.url, isEnabled: value.isEnabled))
        }
    }

    func applyEPGSourceToLocal(_ value: EPGSourceValues?, id: UUID, local: EPGSource?) {
        guard let value else {
            if let local { catalogContext.delete(local) }
            return
        }
        if let local {
            local.name = value.name
            local.url = value.url
            local.isEnabled = value.isEnabled
        } else {
            let source = EPGSource(name: value.name, url: value.url, playlistID: nil)
            source.id = id
            source.isEnabled = value.isEnabled
            catalogContext.insert(source)
        }
    }

    static func playlistRemains(verdict: MergeVerdict<PlaylistConfigValues>, hadLocal: Bool, hadCloud: Bool) -> Bool {
        switch verdict {
        case .noChange: hadLocal || hadCloud
        case let .pushToCloud(value), let .pullToLocal(value): value != nil
        case .writeBoth: true
        }
    }
}

// The per-content mutation helpers (`applyContentToCloud` / `applyContentToLocal`
// / `resetLocalContent`) live in CloudSyncEngine+Content.swift.
