//
//  ReconcileScheduleMachine.swift
//  Lume
//
//  When iCloud sync runs a reconcile, as one explicit state instead of a
//  handful of flags (reconciling, a follow-up queued, an import pending, the
//  launch gate armed). The flags lost things between them: a follow-up forgot
//  why it was asked for, a pass skipped because the local catalog couldn't be
//  read still counted as a sync (and nothing retried it), and none of it could
//  be tested without the notifications that drive it.
//
//  Pure: `CloudSyncCoordinator` feeds requests and outcomes in, and carries out
//  the effects — the debounce, the pass, the retry, the launch gate.
//

import Foundation

nonisolated struct ReconcileScheduleMachine: Equatable {
    enum State: Equatable {
        case idle
        /// A pass is running. Requests arriving meanwhile gather here and run
        /// straight after, as one pass.
        case reconciling(followUp: Set<ReconcileReason>)
        /// The last pass couldn't read the local catalog (a detached or corrupt
        /// store). A retry is scheduled; a finished catalog sync also retries.
        case waitingForCatalog
    }

    /// The launch gate a fresh install waits on before choosing between the
    /// main app and the add-playlist form.
    enum Gate: Equatable {
        case closed
        /// The launch sync is judged settled: opens after the next pass with
        /// nothing queued behind it.
        case armed
        case open
    }

    enum Outcome: Equatable {
        case completed
        case failed
        /// Skipped: the local catalog couldn't be read. Not a sync.
        case catalogUnreadable
    }

    enum Event: Equatable {
        case requested(ReconcileReason, debounced: Bool)
        case debounceElapsed
        case passFinished(Outcome)
        /// CloudKit imported remote data: the next foreground or store-change
        /// request has something to pull.
        case importSeen
        case catalogRetryElapsed
        /// The launch sync is settled (an import finished, the timeout, no
        /// account): open the gate after the next pass.
        case initialSyncSettled
        /// The viewer chose not to wait.
        case gateSkipped
    }

    enum Effect: Equatable {
        /// (Re)start the trailing debounce; `debounceElapsed` follows.
        case startDebounce
        case cancelDebounce
        case runPass(Set<ReconcileReason>)
        case recordSync
        case scheduleCatalogRetry
        case openGate
    }

    private(set) var state: State = .idle
    private(set) var gate: Gate
    private(set) var importPending = false
    /// Reasons gathered while the debounce runs.
    private(set) var requested: Set<ReconcileReason> = []

    init(gateOpen: Bool = false) {
        gate = gateOpen ? .open : .closed
    }

    /// Applies `event`. Nil when it changes nothing — a foreground or
    /// store-change request with no import to pull.
    mutating func handle(_ event: Event) -> [Effect]? {
        switch event {
        case let .requested(reason, debounced):
            return request(reason, debounced: debounced)
        case .debounceElapsed:
            guard !requested.isEmpty else { return nil }
            return runOrQueue(taking: requested)
        case let .passFinished(outcome):
            return finish(outcome)
        case .importSeen:
            importPending = true
            return []
        case .catalogRetryElapsed:
            guard state == .waitingForCatalog else { return nil }
            return runOrQueue(taking: [.catalogRetry])
        case .initialSyncSettled, .gateSkipped:
            return moveGate(event)
        }
    }

    private mutating func moveGate(_ event: Event) -> [Effect]? {
        if event == .gateSkipped {
            guard gate != .open else { return nil }
            gate = .open
            return [.openGate]
        }
        guard gate == .closed else { return nil }
        gate = .armed
        return request(.launch, debounced: true)
    }

    /// A foreground return or a bare store change only has work to do when
    /// CloudKit imported something; everything else always runs.
    private func worthRunning(_ reason: ReconcileReason) -> Bool {
        switch reason {
        case .foreground, .remoteChange: importPending
        default: true
        }
    }

    private mutating func request(_ reason: ReconcileReason, debounced: Bool) -> [Effect]? {
        guard worthRunning(reason) else { return nil }
        requested.insert(reason)
        guard debounced else { return [.cancelDebounce] + runOrQueue(taking: requested) }
        return [.startDebounce]
    }

    private mutating func runOrQueue(taking reasons: Set<ReconcileReason>) -> [Effect] {
        requested = []
        if case let .reconciling(followUp) = state {
            state = .reconciling(followUp: followUp.union(reasons))
            return []
        }
        state = .reconciling(followUp: [])
        // This pass pulls whatever was imported; an import mid-pass sets it
        // again.
        importPending = false
        return [.runPass(reasons)]
    }

    private mutating func finish(_ outcome: Outcome) -> [Effect]? {
        guard case let .reconciling(followUp) = state else { return nil }
        var effects: [Effect] = outcome == .completed ? [.recordSync] : []
        if !followUp.isEmpty {
            state = .idle
            return effects + runOrQueue(taking: followUp)
        }
        if outcome == .catalogUnreadable {
            state = .waitingForCatalog
            effects.append(.scheduleCatalogRetry)
        } else {
            state = .idle
        }
        // A pass that ran with nothing behind it settles the launch sync —
        // even one that couldn't read the catalog: the gate is about not
        // stranding a fresh install on a spinner.
        if gate == .armed {
            gate = .open
            effects.append(.openGate)
        }
        return effects
    }
}

// MARK: - Journal names

nonisolated extension ReconcileScheduleMachine.State {
    var logName: String {
        switch self {
        case .idle: "idle"
        case let .reconciling(followUp) where followUp.isEmpty: "reconciling"
        case let .reconciling(followUp): "reconciling (then \(ReconcileReason.logList(followUp)))"
        case .waitingForCatalog: "waitingForCatalog"
        }
    }
}

nonisolated extension ReconcileReason {
    static func logList(_ reasons: Set<ReconcileReason>) -> String {
        reasons.map { String(describing: $0) }.sorted().joined(separator: ", ")
    }
}
