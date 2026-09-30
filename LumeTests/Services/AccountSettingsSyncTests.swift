//
//  AccountSettingsSyncTests.swift
//  LumeTests
//
//  Player and search choices follow the account: merged key by key against a
//  baseline, adopted by a fresh device rather than overwritten by its
//  defaults, and carried between devices by the reconcile.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
@Suite(.globalState)
struct AccountSettingsSyncTests {
    private let priority = PlayerSettings.enginePriorityKey
    private let autoPlay = PlayerSettings.Playback.autoPlayNextKey
    private let languages = PlayerSettings.Language.preferredAudioLanguagesKey

    private func values(_ pairs: [String: SyncedSettingValue]) -> AccountSettingsValues {
        AccountSettingsValues(values: pairs)
    }

    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AccountSettingsSyncTests.\(UUID().uuidString)")!
    }

    // MARK: - Merge

    /// A new device has set nothing: it takes the account's choices and
    /// publishes none of its defaults.
    @Test func `a fresh device adopts the account's settings`() {
        let cloud = values([priority: .string("ksPlayer,vlcKit,avPlayer"), autoPlay: .bool(false)])
        let outcome = AccountSettingsSync.merge(local: values([:]), cloud: cloud, shadow: nil)

        #expect(outcome.cloudWrite == nil)
        #expect(outcome.localWrites[priority] == .some(.string("ksPlayer,vlcKit,avPlayer")))
        #expect(outcome.localWrites[autoPlay] == .some(.bool(false)))
        #expect(outcome.shadow == cloud)
    }

    @Test func `the first device publishes what it has set`() {
        let local = values([priority: .string("vlcKit,ksPlayer,avPlayer")])
        let outcome = AccountSettingsSync.merge(local: local, cloud: nil, shadow: nil)

        #expect(outcome.cloudWrite == local)
        #expect(outcome.localWrites.isEmpty)
        #expect(outcome.pushed == 1)
    }

    /// Languages changed on one device and autoplay on another: both stand.
    @Test func `different settings changed on two devices both survive`() {
        let base = values([languages: .string("en"), autoPlay: .bool(true)])
        let local = values([languages: .string("en,de"), autoPlay: .bool(true)])
        let cloud = values([languages: .string("en"), autoPlay: .bool(false)])
        let outcome = AccountSettingsSync.merge(local: local, cloud: cloud, shadow: base)

        #expect(outcome.cloudWrite == values([languages: .string("en,de"), autoPlay: .bool(false)]))
        #expect(outcome.localWrites == [autoPlay: .some(.bool(false))])
    }

    @Test func `the same setting changed on both sides takes iCloud's`() {
        let base = values([priority: .string("ksPlayer")])
        let outcome = AccountSettingsSync.merge(
            local: values([priority: .string("vlcKit")]),
            cloud: values([priority: .string("avPlayer")]),
            shadow: base
        )

        #expect(outcome.localWrites[priority] == .some(.string("avPlayer")))
        #expect(outcome.shadow[priority] == .string("avPlayer"))
    }

    /// A newer version's setting this build doesn't sync rides through a push.
    @Test func `settings this build doesn't know are kept`() {
        let cloud = values(["player.someFutureChoice": .bool(true)])
        let outcome = AccountSettingsSync.merge(local: values([autoPlay: .bool(false)]), cloud: cloud, shadow: nil)

        #expect(outcome.cloudWrite?["player.someFutureChoice"] == .bool(true))
        #expect(outcome.cloudWrite?[autoPlay] == .bool(false))
    }

    @Test func `settled settings write nothing`() {
        let agreed = values([priority: .string("ksPlayer"), autoPlay: .bool(true)])
        let outcome = AccountSettingsSync.merge(local: agreed, cloud: agreed, shadow: agreed)

        #expect(outcome.cloudWrite == nil)
        #expect(outcome.localWrites.isEmpty)
    }

    @Test func `only synced settings are read, with their types`() {
        let defaults = scratchDefaults()
        defaults.set("ksPlayer,avPlayer", forKey: priority)
        defaults.set(false, forKey: autoPlay)
        defaults.set(12, forKey: PlayerSettings.KSPlayer.vodBufferKey) // tuning stays local

        let snapshot = AccountSettingsSync.snapshot(from: defaults)
        #expect(snapshot == values([priority: .string("ksPlayer,avPlayer"), autoPlay: .bool(false)]))
    }

    // MARK: - Through the reconcile

    /// Set on one device, picked up by another sharing the iCloud store.
    @Test func `a setting chosen on one device reaches another`() async throws {
        let container = try makeProfileTestContainer()
        let appleTV = scratchDefaults()
        let phone = scratchDefaults()
        appleTV.set("ksPlayer,vlcKit,avPlayer", forKey: priority)
        appleTV.set(false, forKey: autoPlay)

        let appleTVEngine = CloudSyncEngine(container: container, shadow: shadow(), settingsDefaults: appleTV)
        let pushed = await appleTVEngine.reconcile()
        #expect(pushed.settingsPushed == 2)

        let phoneEngine = CloudSyncEngine(container: container, shadow: shadow(), settingsDefaults: phone)
        let pulled = await phoneEngine.reconcile()
        #expect(pulled.settingsPulled == 2)
        #expect(phone.string(forKey: priority) == "ksPlayer,vlcKit,avPlayer")
        #expect(phone.object(forKey: autoPlay) as? Bool == false)
        #expect(try container.mainContext.fetch(FetchDescriptor<SyncedAccountSettings>()).count == 1)
    }

    /// A failed pass restores its checkpoint: every baseline has to be in it,
    /// or a failure leaves that one half-advanced. Simkl's once wasn't.
    @Test func `a checkpoint restores the Simkl and settings baselines`() {
        let shadow = shadow()
        let simkl = SimklCredentialValues(tokens: SimklTokens(
            accessToken: "a", refreshToken: "r", issuedAt: 1_700_000_000,
            expiresIn: 604_800, scope: nil, tokenType: "Bearer"
        ))
        let settings = values([autoPlay: .bool(false)])
        shadow.setSimklCredentialShadow(simkl)
        shadow.setAccountSettingsShadow(settings)
        let checkpoint = shadow.checkpoint()

        shadow.setSimklCredentialShadow(nil)
        shadow.setAccountSettingsShadow(values([:]))
        shadow.restore(checkpoint)

        #expect(shadow.simklCredentialShadow() == simkl)
        #expect(shadow.accountSettingsShadow() == settings)
    }

    private func shadow() -> CloudSyncShadow {
        CloudSyncShadow(defaults: scratchDefaults())
    }
}
