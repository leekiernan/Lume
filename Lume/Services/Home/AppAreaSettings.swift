//
//  AppAreaSettings.swift
//  Lume
//
//  Which areas of the app are switched on. A disabled area leaves the top
//  navigation entirely *and* stops being synced — `ContentSyncManager` skips
//  its content type, and the EPG import is skipped with Live TV. Rows already
//  in the store are left alone, so re-enabling shows them immediately and the
//  next sync brings them up to date.
//
//  This is the single place the preference's key is built and read. When the
//  layout eventually moves per-profile, that scoping lands here rather than in
//  every caller — see `enabledAreas(disabledRaw:)`'s callers, which all pass a
//  value they were handed rather than reading defaults themselves.
//

import Foundation

nonisolated enum AppAreaSettings {
    /// Areas the user has switched off, as a comma-separated list of raw
    /// values. Absence means enabled, so the default (empty) shows everything.
    /// Scoped to the active profile — see `ProfileScopedPreferences`.
    static var disabledAreasKey: String {
        ProfileScopedPreferences.key(baseDisabledAreasKey)
    }

    /// The unscoped form — see `HomeLayoutSettings.baseSectionOrderKey`.
    static let baseDisabledAreasKey = "nav.disabledAreas.v1"

    static func decodeDisabled(_ raw: String) -> Set<AppArea> {
        Set(raw.split(separator: ",").compactMap { AppArea(rawValue: String($0)) })
    }

    /// Encode in a stable order so the stored value doesn't churn as the set is
    /// mutated.
    static func encodeDisabled(_ areas: Set<AppArea>) -> String {
        areas.map(\.rawValue).sorted().joined(separator: ",")
    }

    static func isEnabled(_ area: AppArea, disabledRaw: String) -> Bool {
        !decodeDisabled(disabledRaw).contains(area)
    }

    /// The areas to show, in declaration order. Never empty: if every area were
    /// somehow disabled the app would have no navigation at all, so Home is
    /// restored as the floor.
    static func enabledAreas(disabledRaw: String) -> [AppArea] {
        let enabled = AppArea.allCases.filter { isEnabled($0, disabledRaw: disabledRaw) }
        return enabled.isEmpty ? [.home] : enabled
    }

    /// Enabled areas that own a provider catalog phase. Home is navigation and
    /// layout only, so it never makes a playlist sync incomplete by itself.
    static func enabledContentAreas(disabledRaw: String) -> Set<AppArea> {
        Set(AppArea.allCases.filter {
            $0.categoryType != nil && isEnabled($0, disabledRaw: disabledRaw)
        })
    }

    /// Flip one area's state, returning the new encoded set. Switching off the
    /// last enabled area is refused — the caller's toggle snaps back, because
    /// the getter still reports it as on.
    static func settingEnabled(
        _ isOn: Bool,
        for area: AppArea,
        disabledRaw: String
    ) -> String {
        var disabled = decodeDisabled(disabledRaw)
        if isOn {
            disabled.remove(area)
        } else {
            guard enabledAreas(disabledRaw: disabledRaw).count > 1 else { return disabledRaw }
            disabled.insert(area)
        }
        return encodeDisabled(disabled)
    }

    /// Whether switching `area` off is allowed — false for the last one left.
    /// Lets the UI disable the control rather than silently ignoring a tap.
    static func canDisable(_ area: AppArea, disabledRaw: String) -> Bool {
        guard isEnabled(area, disabledRaw: disabledRaw) else { return true }
        return enabledAreas(disabledRaw: disabledRaw).count > 1
    }

    // MARK: - Non-view readers

    /// For callers outside SwiftUI — the sync manager and the EPG import, which
    /// run on background contexts and have no @AppStorage to observe. Reads the
    /// same key the settings screen writes.
    static func isEnabled(_ area: AppArea) -> Bool {
        isEnabled(area, disabledRaw: storedValue)
    }

    /// Reads only the area set. Deliberately *not* routed through
    /// `areaState()`: this runs per item inside the sync loops, and a job that
    /// needs the generation needs it captured once at request start, not
    /// re-read here. Fenced callers use `areaState(profileID:defaults:)`.
    static var storedValue: String {
        UserDefaults.standard.string(forKey: disabledAreasKey) ?? ""
    }
}

/// A stamp over one profile's enabled-area set, bumped on every write to it.
///
/// Background jobs capture it at request start and compare the captured value
/// against the live one before they publish (`Fence`). Without it a mid-run
/// toggle changes a sync's behaviour halfway through, because
/// `AppAreaSettings.isEnabled(_:)` reads `UserDefaults` live.
///
/// Wrapping arithmetic is deliberate: at one bump per toggle, `UInt64` does not
/// run out, and trapping on an impossible overflow would be a worse failure
/// than repeating a generation after 18 quintillion toggles.
nonisolated struct AreaGenerationToken: Hashable {
    let rawValue: UInt64

    static let initial = AreaGenerationToken(rawValue: 0)

    func bumped() -> AreaGenerationToken {
        AreaGenerationToken(rawValue: rawValue &+ 1)
    }
}

// MARK: - The area set and its generation, as one value

/// `nonisolated` on the extension, not just on `AppAreaSettings`: extension
/// members do not inherit the enum's isolation, and the sync engine reads this
/// pair from background actors.
nonisolated extension AppAreaSettings {
    /// The enabled-area set and the generation that stamps it. These two are
    /// only ever read and written together — see `persist(disabledRaw:...)`.
    nonisolated struct AreaState: Equatable {
        let disabledRaw: String
        let generation: AreaGenerationToken
    }

    /// The unscoped generation key — the scoped form is per profile, like the
    /// area set it stamps.
    static let baseAreaGenerationKey = "nav.areaGeneration.v1"

    static func areaGenerationKey(profileID: UUID?) -> String {
        ProfileScopedPreferences.key(baseAreaGenerationKey, profileID: profileID)
    }

    static func disabledAreasKey(profileID: UUID?) -> String {
        ProfileScopedPreferences.key(baseDisabledAreasKey, profileID: profileID)
    }

    /// Reads both halves under the write lock, so an in-process reader never
    /// observes the moment between the two `UserDefaults` writes.
    static func areaState(
        profileID: UUID? = ActiveProfileStore.current,
        defaults: UserDefaults = .standard
    ) -> AreaState {
        pairLock.lock()
        defer { pairLock.unlock() }
        return unlockedAreaState(profileID: profileID, defaults: defaults)
    }

    /// The only way the enabled-area set reaches storage. It always bumps the
    /// generation, so the split write — a new area set stamped with the old
    /// generation, which a stale job would sail straight past — is not
    /// something a caller can express.
    ///
    /// The generation is written *first*. Another process (the widget
    /// extension) can still catch the gap between the two writes, and the
    /// order decides which way it fails: a newer generation beside an older
    /// area set fails the fence and supersedes the job, which is the safe
    /// direction. The reverse order would let a stale job pass the fence and
    /// publish into an area set it never saw.
    @discardableResult
    static func persist(
        disabledRaw: String,
        profileID: UUID? = ActiveProfileStore.current,
        defaults: UserDefaults = .standard
    ) -> AreaState {
        pairLock.lock()
        defer { pairLock.unlock() }
        let generation = unlockedAreaState(profileID: profileID, defaults: defaults).generation.bumped()
        defaults.set(String(generation.rawValue), forKey: areaGenerationKey(profileID: profileID))
        defaults.set(disabledRaw, forKey: disabledAreasKey(profileID: profileID))
        return AreaState(disabledRaw: disabledRaw, generation: generation)
    }

    /// Flip one area and store the result. A refused toggle — the last enabled
    /// area — changes nothing and does not bump the generation, so it cannot
    /// supersede work that is still valid.
    @discardableResult
    static func setEnabled(
        _ isOn: Bool,
        for area: AppArea,
        profileID: UUID? = ActiveProfileStore.current,
        defaults: UserDefaults = .standard
    ) -> AreaState {
        // Recursive so the read-modify-write is one atomic section even though
        // both halves lock in their own right.
        pairLock.lock()
        defer { pairLock.unlock() }
        let current = unlockedAreaState(profileID: profileID, defaults: defaults)
        let updated = settingEnabled(isOn, for: area, disabledRaw: current.disabledRaw)
        guard updated != current.disabledRaw else { return current }
        return persist(disabledRaw: updated, profileID: profileID, defaults: defaults)
    }

    private static let pairLock = NSRecursiveLock()

    private static func unlockedAreaState(profileID: UUID?, defaults: UserDefaults) -> AreaState {
        // Stored as a string: `UserDefaults` has no `UInt64`, and going via
        // `Int` would make the stored form depend on the word size.
        let raw = defaults.string(forKey: areaGenerationKey(profileID: profileID)).flatMap(UInt64.init)
        return AreaState(
            disabledRaw: defaults.string(forKey: disabledAreasKey(profileID: profileID)) ?? "",
            generation: raw.map(AreaGenerationToken.init(rawValue:)) ?? .initial
        )
    }
}
