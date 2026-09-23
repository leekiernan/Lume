import Foundation
import OSLog
import SwiftData

/// Mirrors the Trakt credential lifecycle for Simkl. OAuth tokens remain in
/// the keychain locally; CloudKit encrypted fields carry the newest pair to
/// other Lume devices, including tvOS where iCloud Keychain is not available.
extension CloudSyncEngine {
    func reconcileSimklCredentials(into result: inout CloudSyncReconcileResult) throws {
        let local: SimklCredentialValues?
        switch SimklTokenStore.storedTokens() {
        case let .tokens(tokens):
            local = SimklCredentialValues(tokens: tokens)
        case .notSet:
            local = nil
        case .unavailable:
            Logger.sync.info("Simkl keychain unreadable (device locked?) — skipping credential merge this pass")
            result.simklPending += 1
            return
        }

        let mirror = try fetchSimklAccountMirror()
        let cloud = mirror.map { Self.simklValues(from: $0) }
        let verdict = SimklCredentialValues.reconcile(
            local: local,
            cloud: cloud,
            shadow: shadow.simklCredentialShadow()
        )
        applySimklVerdict(verdict, mirror: mirror, into: &result)
    }

    private func applySimklVerdict(
        _ verdict: MergeVerdict<SimklCredentialValues>,
        mirror: SyncedSimklAccount?,
        into result: inout CloudSyncReconcileResult
    ) {
        switch verdict {
        case .noChange:
            break
        case let .pushToCloud(value):
            applySimklToCloud(value, mirror: mirror)
            result.simklPushed += 1
            shadow.setSimklCredentialShadow(value)
        case let .pullToLocal(value):
            guard applySimklToLocal(value) else {
                result.simklPending += 1
                return
            }
            result.simklPulled += 1
            shadow.setSimklCredentialShadow(value)
        case let .writeBoth(value):
            guard applySimklToLocal(value) else {
                result.simklPending += 1
                return
            }
            applySimklToCloud(value, mirror: mirror)
            result.simklPushed += 1
            result.simklPulled += 1
            shadow.setSimklCredentialShadow(value)
        }
    }

    private func applySimklToLocal(_ value: SimklCredentialValues?) -> Bool {
        guard let value else { return SimklTokenStore.clear() }
        guard let tokens = value.tokens else { return false }
        return SimklTokenStore.save(tokens)
    }

    private func applySimklToCloud(_ value: SimklCredentialValues?, mirror: SyncedSimklAccount?) {
        guard let value else {
            if let mirror { cloudContext.delete(mirror) }
            return
        }
        guard let tokens = value.tokens else { return }
        let timestamp = Date(timeIntervalSince1970: tokens.issuedAt)
        guard let mirror else {
            cloudContext.insert(SyncedSimklAccount(tokens: tokens, updatedAt: timestamp))
            return
        }
        guard Self.simklValues(from: mirror) != value else { return }
        mirror.accessToken = tokens.accessToken
        mirror.refreshToken = tokens.refreshToken
        mirror.issuedAt = tokens.issuedAt
        mirror.expiresIn = tokens.expiresIn
        mirror.scope = tokens.scope
        mirror.tokenType = tokens.tokenType
        mirror.updatedAt = timestamp
    }

    private func fetchSimklAccountMirror() throws -> SyncedSimklAccount? {
        var winner: SyncedSimklAccount?
        for record in try cloudContext.fetch(FetchDescriptor<SyncedSimklAccount>()) {
            guard !record.accessToken.isEmpty, !record.refreshToken.isEmpty else {
                cloudContext.delete(record)
                continue
            }
            winner = dedupe(record, against: winner, updatedAt: \.updatedAt)
        }
        return winner
    }

    private static func simklValues(from mirror: SyncedSimklAccount) -> SimklCredentialValues {
        SimklCredentialValues(tokens: SimklTokens(
            accessToken: mirror.accessToken,
            refreshToken: mirror.refreshToken,
            issuedAt: mirror.issuedAt,
            expiresIn: mirror.expiresIn,
            scope: mirror.scope,
            tokenType: mirror.tokenType
        ))
    }
}
