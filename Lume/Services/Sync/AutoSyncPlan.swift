//
//  AutoSyncPlan.swift
//  Lume
//
//  What an automatic sync of one playlist should do right now: nothing, its
//  regular refresh, or a repair of areas the active profile enables but whose
//  own refresh is missing or stale (`PlaylistSyncCoverage`). Pure, so the
//  queue's decisions — including the once-a-session repair rule — are tested
//  without SwiftUI or SwiftData state.
//

import Foundation

extension AutoSync {
    /// The areas each playlist has had an automatic repair for this session.
    ///
    /// A repair isn't held back by the session's regular refresh: switching to
    /// a profile that enables Live TV can need one after the launch refresh
    /// ran. But each area is tried once a session, so one that fails doesn't
    /// retry on every trigger. New connection details from iCloud reset a
    /// failed playlist, the same as its regular attempt.
    struct RepairLedger {
        private var attempted: [UUID: Set<AppArea>] = [:]

        func untried(_ areas: Set<AppArea>, for playlistID: UUID) -> Set<AppArea> {
            areas.subtracting(attempted[playlistID] ?? [])
        }

        mutating func record(_ areas: Set<AppArea>, for playlistID: UUID) {
            guard !areas.isEmpty else { return }
            attempted[playlistID, default: []].formUnion(areas)
        }

        mutating func reset(_ playlistID: UUID) {
            attempted[playlistID] = nil
        }
    }

    struct Plan: Equatable {
        /// The areas to fetch alone, or `nil` for the regular refresh of every
        /// area the profile enables.
        let repairingAreas: Set<AppArea>?
        /// Areas this run repairs, for the ledger. Includes a full refresh
        /// that only ran because an area was stale, so a failing source
        /// without per-area imports doesn't retry on every trigger either.
        let repairedAreas: Set<AppArea>
        /// A repair of areas the catalog already has rows for runs without the
        /// blocking cover.
        let runsInBackground: Bool
    }

    /// One playlist as the plan sees it.
    struct PlanInput {
        let candidate: Candidate
        let playlistID: UUID
        let frequency: SyncFrequency
        /// Whether this session's regular attempt already ran. Holds back the
        /// regular refresh only; repairs answer to the ledger.
        let alreadyStarted: Bool
        /// Enabled areas owed a refresh by their own date, less any the viewer
        /// deferred (`PlaylistSyncCoverage.missingAreasForAutomaticRepair`).
        let staleAreas: Set<AppArea>
        /// Whether the source can import one area alone. Only Xtream can; m3u
        /// and Stalker get their regular refresh instead.
        let supportsAreaRepair: Bool
    }

    /// `areasWithRows` — the areas already browsable — is read only for a
    /// repair, since it costs a catalog fetch.
    static func plan(
        _ input: PlanInput,
        ledger: RepairLedger,
        areasWithRows: () -> Set<AppArea>,
        now: Date = Date()
    ) -> Plan? {
        let candidate = input.candidate
        let isRegularlyDue = shouldSync(candidate, frequency: input.frequency, alreadyStarted: input.alreadyStarted, now: now)
        let untried = ledger.untried(input.staleAreas, for: input.playlistID)
        let needsRepair = !untried.isEmpty && isEligible(candidate, alreadyStarted: false)
        guard isRegularlyDue || needsRepair else { return nil }
        guard !isRegularlyDue else {
            return Plan(repairingAreas: nil, repairedAreas: [], runsInBackground: false)
        }
        guard input.supportsAreaRepair else {
            return Plan(repairingAreas: nil, repairedAreas: untried, runsInBackground: false)
        }
        // Only an area with nothing to browse yet is worth blocking the
        // screen for; one already in the catalog refreshes behind it.
        return Plan(
            repairingAreas: untried,
            repairedAreas: untried,
            runsInBackground: untried.isSubset(of: areasWithRows())
        )
    }
}
