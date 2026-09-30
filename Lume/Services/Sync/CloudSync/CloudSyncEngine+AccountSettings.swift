//
//  CloudSyncEngine+AccountSettings.swift
//  Lume
//
//  The account-wide settings pass: this device's player and search choices
//  (`AccountSettingsSync.keys`, in `UserDefaults`) against their iCloud mirror
//  (`SyncedAccountSettings`). Not profile-scoped, so it runs once per pass.
//

import Foundation
import OSLog
import SwiftData

extension CloudSyncEngine {
    func reconcileAccountSettings(into result: inout CloudSyncReconcileResult) throws {
        let mirror = try fetchAccountSettingsMirror()
        let cloud: AccountSettingsValues?
        if let mirror, !mirror.valuesJSON.isEmpty {
            guard let decoded = AccountSettingsSync.decode(mirror.valuesJSON) else {
                // Unreadable — a format this build doesn't know. Reading it as
                // empty would push this device's settings over it; leave both
                // sides and the baseline alone instead.
                Logger.sync.error("Account settings in iCloud are unreadable — skipping settings merge")
                return
            }
            cloud = decoded
        } else {
            cloud = nil
        }

        let outcome = AccountSettingsSync.merge(
            local: AccountSettingsSync.snapshot(from: settingsDefaults),
            cloud: cloud,
            shadow: shadow.accountSettingsShadow()
        )
        AccountSettingsSync.apply(outcome.localWrites, to: settingsDefaults)
        if let values = outcome.cloudWrite, let json = AccountSettingsSync.encode(values) {
            if let mirror {
                mirror.valuesJSON = json
                mirror.updatedAt = Date()
            } else {
                cloudContext.insert(SyncedAccountSettings(valuesJSON: json))
            }
        }
        shadow.setAccountSettingsShadow(outcome.shadow)
        result.settingsPushed += outcome.pushed
        result.settingsPulled += outcome.pulled
    }

    private func fetchAccountSettingsMirror() throws -> SyncedAccountSettings? {
        var winner: SyncedAccountSettings?
        for record in try cloudContext.fetch(FetchDescriptor<SyncedAccountSettings>()) {
            winner = dedupe(record, against: winner, updatedAt: \.updatedAt)
        }
        return winner
    }
}
