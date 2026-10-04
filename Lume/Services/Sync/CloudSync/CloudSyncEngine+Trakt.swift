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
        // A token missing from the keychain is a disconnect only if the user
        // disconnected here; otherwise it was lost, and the cloud copy wins.
        let verdict = TraktCredentialValues.reconcile(
            local: local,
            cloud: cloud,
            shadow: shadow.traktCredentialShadow(),
            linkState: CredentialLinkStateStore.state(for: .trakt)
        )
        applyTraktVerdict(verdict, mirror: mirror, into: &result)
    }

    private func applyTraktVerdict(
        _ verdict: MergeVerdict<TraktCredentialValues>,
        mirror: SyncedTraktAccount?,
        into result: inout CloudSyncReconcileResult
    ) {
        let effects = CredentialMergeApplication.apply(
            verdict,
            writeLocal: applyTraktToLocal,
            writeCloud: { applyTraktToCloud($0, mirror: mirror) },
            recordShadow: shadow.setTraktCredentialShadow
        )
        result.traktPushed += effects.pushed
        result.traktPulled += effects.pulled
        result.traktPending += effects.pending
        if effects.deletionPushed { result.credentialDeletionsPushed.insert(.trakt) }
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
        try fetchCredentialMirror(
            FetchDescriptor<SyncedTraktAccount>(),
            isValid: { !$0.accessToken.isEmpty && !$0.refreshToken.isEmpty },
            updatedAt: \.updatedAt
        )
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
