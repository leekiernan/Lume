//
//  CloudSyncEngine+Trakt.swift
//  Lume
//
//  Carries the app-wide Trakt OAuth authorization between devices. The local
//  keychain remains the store of record; CloudKit encrypted fields are the
//  transport because synchronizable Keychain items do not reach tvOS.
//

import Foundation
import OSLog
import SwiftData

extension CloudSyncEngine {
    func reconcileTraktCredentials(into result: inout CloudSyncReconcileResult) throws {
        let local: TraktCredentialValues?
        switch TraktTokenStore.storedTokens() {
        case let .tokens(tokens):
            local = TraktCredentialValues(tokens: tokens)
        case .notSet:
            local = nil
        case .unavailable:
            // A locked/unavailable keychain is not a disconnect. Leave every
            // side and the baseline untouched until an unlocked pass can tell.
            Logger.sync.info("Trakt keychain unreadable (device locked?) — skipping credential merge this pass")
            result.traktPending += 1
            return
        }

        let mirror = try fetchTraktAccountMirror()
        let cloud = mirror.map { Self.traktValues(from: $0) }
        let verdict = TraktCredentialValues.reconcile(
            local: local,
            cloud: cloud,
            shadow: shadow.traktCredentialShadow()
        )
        applyTraktVerdict(verdict, mirror: mirror, into: &result)
    }

    private func applyTraktVerdict(
        _ verdict: MergeVerdict<TraktCredentialValues>,
        mirror: SyncedTraktAccount?,
        into result: inout CloudSyncReconcileResult
    ) {
        switch verdict {
        case .noChange:
            break
        case let .pushToCloud(value):
            applyTraktToCloud(value, mirror: mirror)
            result.traktPushed += 1
            shadow.setTraktCredentialShadow(value)
        case let .pullToLocal(value):
            guard applyTraktToLocal(value) else {
                result.traktPending += 1
                return
            }
            result.traktPulled += 1
            shadow.setTraktCredentialShadow(value)
        case let .writeBoth(value):
            guard applyTraktToLocal(value) else {
                result.traktPending += 1
                return
            }
            applyTraktToCloud(value, mirror: mirror)
            result.traktPushed += 1
            result.traktPulled += 1
            shadow.setTraktCredentialShadow(value)
        }
    }

    private func applyTraktToLocal(_ value: TraktCredentialValues?) -> Bool {
        guard let value else { return TraktTokenStore.clear() }
        guard let tokens = value.tokens else { return false }
        return TraktTokenStore.save(tokens)
    }

    private func applyTraktToCloud(_ value: TraktCredentialValues?, mirror: SyncedTraktAccount?) {
        guard let value else {
            if let mirror { cloudContext.delete(mirror) }
            return
        }
        guard let tokens = value.tokens else { return }
        let timestamp = Date(timeIntervalSince1970: tokens.createdAt)
        guard let mirror else {
            cloudContext.insert(SyncedTraktAccount(tokens: tokens, updatedAt: timestamp))
            return
        }
        guard Self.traktValues(from: mirror) != value else { return }
        mirror.accessToken = tokens.accessToken
        mirror.refreshToken = tokens.refreshToken
        mirror.createdAt = tokens.createdAt
        mirror.expiresIn = tokens.expiresIn
        mirror.scope = tokens.scope
        mirror.tokenType = tokens.tokenType
        mirror.updatedAt = timestamp
    }

    private func fetchTraktAccountMirror() throws -> SyncedTraktAccount? {
        var winner: SyncedTraktAccount?
        for record in try cloudContext.fetch(FetchDescriptor<SyncedTraktAccount>()) {
            guard !record.accessToken.isEmpty, !record.refreshToken.isEmpty else {
                cloudContext.delete(record)
                continue
            }
            winner = dedupe(record, against: winner, updatedAt: \.updatedAt)
        }
        return winner
    }

    private static func traktValues(from mirror: SyncedTraktAccount) -> TraktCredentialValues {
        TraktCredentialValues(tokens: TraktTokens(
            accessToken: mirror.accessToken,
            refreshToken: mirror.refreshToken,
            createdAt: mirror.createdAt,
            expiresIn: mirror.expiresIn,
            scope: mirror.scope,
            tokenType: mirror.tokenType
        ))
    }
}
