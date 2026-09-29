//
//  CloudSyncEngine+ContentReconcile.swift
//  Lume
//
//  The content pass of a reconcile: read each title's state on both sides as
//  what it is — state, the viewer's clear, a blank or missing catalog row, an
//  absent record — and apply `ContentIntentMerge`'s verdict. Split out of
//  CloudSyncEngine.swift (the 600-line cap).
//

import Foundation
import SwiftData

extension CloudSyncEngine {
    func reconcileContent(livePrefixes: Set<String>, into result: inout CloudSyncReconcileResult) throws {
        let mirrors = try fetchContentMirrors()
        let localValues = try fetchLocalContentValues()
        // A snapshot: clears recorded while this pass runs wait for the next.
        let cleared = clears.ids
        result.contentClearsSeen = cleared

        var ids = Set(mirrors.keys).union(localValues.keys)
        ids.formUnion(shadow.contentShadowIDs())

        var live: [String] = []
        for id in ids {
            // Garbage-collect state whose owning playlist no longer exists on
            // either side (deleted however): an explicit deletion, not a clear.
            guard livePrefixes.contains(String(id.prefix(36))) else {
                if let mirror = mirrors[id] { cloudContext.delete(mirror) }
                if let entry = localValues[id] { resetLocalContent(entry) }
                shadow.setContentShadow(id, nil)
                continue
            }
            live.append(id)
        }

        let rows = try catalogRows(
            forBlank: live.filter { localValues[$0] == nil },
            mirrors: mirrors, cleared: cleared
        )
        for id in live {
            let row = localValues[id]?.model ?? rows[id]
            let local: LocalContentReading = if let entry = localValues[id] {
                .state(entry.values)
            } else if row == nil {
                .missingRow
            } else {
                cleared.contains(id) ? .clearedByUser : .blank
            }
            let cloud: CloudContentReading = mirrors[id].map { .state(Self.values(from: $0)) } ?? .absent
            let verdict = ContentIntentMerge.reconcile(local: local, cloud: cloud, shadow: shadow.contentShadow(id))
            try apply(verdict, id: id, mirror: mirrors[id], row: row, into: &result)
        }
    }

    /// The catalog rows behind ids with no local state, in one batched fetch
    /// per kind. The kind comes from the cloud record; a clear of a title the
    /// cloud has no record of (rare) is looked for under every kind. With
    /// neither, nothing on either side can change and no row is needed.
    private func catalogRows(
        forBlank ids: [String],
        mirrors: [String: UserContentState],
        cleared: Set<String>
    ) throws -> [String: any PersistentModel] {
        var byKind: [SyncedContentKind: [String]] = [:]
        for id in ids {
            if let kind = mirrors[id]?.kind {
                byKind[kind, default: []].append(id)
            } else if cleared.contains(id) {
                for kind in SyncedContentKind.allCases {
                    byKind[kind, default: []].append(id)
                }
            }
        }
        return try fetchCatalogModels(byKind: byKind)
    }

    private func apply(
        _ verdict: ContentIntentVerdict,
        id: String,
        mirror: UserContentState?,
        row: (any PersistentModel)?,
        into result: inout CloudSyncReconcileResult
    ) throws {
        let kind = mirror?.kind ?? Self.kind(of: row)
        switch verdict {
        case .noChange:
            break
        case .pending:
            result.contentPending += 1
        case let .pushToCloud(value):
            applyContentToCloud(value, id: id, kind: kind, mirror: mirror)
            result.contentPushed += 1
            shadow.setContentShadow(id, value)
        case let .pullToLocal(value):
            guard try applyContentToLocal(value, id: id, kind: kind, loaded: row) else {
                result.contentPending += 1
                return
            }
            result.contentPulled += 1
            shadow.setContentShadow(id, value)
        case let .writeBoth(value):
            guard try applyContentToLocal(value, id: id, kind: kind, loaded: row) else {
                result.contentPending += 1
                return
            }
            applyContentToCloud(value, id: id, kind: kind, mirror: mirror)
            result.contentPushed += 1
            shadow.setContentShadow(id, value)
        }
    }
}
