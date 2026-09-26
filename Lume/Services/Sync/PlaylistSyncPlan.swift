//
//  PlaylistSyncPlan.swift
//  Lume
//
//  A snapshot of the profile-aware work one playlist refresh will perform.
//  The progress UI and the synchroniser share it so the UI never promises
//  phases which the active profile has deliberately switched off.
//

import Foundation

nonisolated struct PlaylistSyncPlan: Equatable {
    let sourceType: PlaylistSourceType
    let full: Bool
    let repairingAreas: Set<AppArea>?
    let syncAreas: Set<AppArea>
    let skippedForProfile: Set<AppArea>
    let deferredByRepair: Set<AppArea>
    let unsupportedBySource: Set<AppArea>

    init(
        sourceType: PlaylistSourceType,
        full: Bool = false,
        repairingAreas: Set<AppArea>? = nil,
        enabledAreas: Set<AppArea>
    ) {
        self.sourceType = sourceType
        self.full = full
        self.repairingAreas = repairingAreas

        let allContentAreas = Set(AppArea.allCases.filter { $0.categoryType != nil })
        let unsupported = ContentSyncManager.unsupportedAreas(for: sourceType)
        let supplied = allContentAreas.subtracting(unsupported)
        let requested = ContentSyncManager.syncAreas(enabled: enabledAreas, repairing: repairingAreas)

        syncAreas = requested.intersection(supplied)
        skippedForProfile = supplied.subtracting(enabledAreas)
        deferredByRepair = repairingAreas == nil ? [] : enabledAreas.intersection(supplied).subtracting(syncAreas)
        unsupportedBySource = unsupported
    }

    init(
        sourceType: PlaylistSourceType,
        full: Bool = false,
        repairingAreas: Set<AppArea>? = nil,
        disabledAreasRaw: String = AppAreaSettings.storedValue
    ) {
        self.init(
            sourceType: sourceType,
            full: full,
            repairingAreas: repairingAreas,
            enabledAreas: AppAreaSettings.enabledContentAreas(disabledRaw: disabledAreasRaw)
        )
    }

    var steps: [SyncStep] {
        SyncStep.steps(for: sourceType, full: full, areas: syncAreas)
    }

    /// A successful content refresh should ask the guide service to catch up
    /// only when this run actually refreshed Live TV. This keeps a VOD-only
    /// profile from downloading XMLTV it cannot show.
    var refreshesGuide: Bool {
        syncAreas.contains(.liveTV)
    }
}
