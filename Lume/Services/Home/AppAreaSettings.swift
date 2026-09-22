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
    static let disabledAreasKey = "nav.disabledAreas.v1"

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

    static var storedValue: String {
        UserDefaults.standard.string(forKey: disabledAreasKey) ?? ""
    }
}
