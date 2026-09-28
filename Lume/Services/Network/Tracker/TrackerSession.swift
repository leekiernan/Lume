//
//  TrackerSession.swift
//  Lume
//
//  The sign-in lifecycle shared by the Trakt and Simkl services: the OAuth
//  device flow (request a code, wait for approval on another screen) and the
//  connected session it leads to.
//
//  "Connected" means this device holds the account's tokens. Who the account
//  belongs to is a separate fact that can lag: after a reinstall the tokens
//  come back from iCloud while the remembered name does not, and fetching it
//  needs the network. The session says so (`connected(account: nil)`) and asks
//  for the identity to be resolved, rather than reading a missing name as
//  "not connected" and offering Connect on a device that already is.
//
//  Pure: the services run the device-flow polling and network calls, feed the
//  outcomes in as events and perform the effects handed back.
//

import Foundation

/// Why a device-flow connect ended without tokens.
enum TrackerConnectFailure: Equatable {
    case codeExpired
    case declined
    case codeUsed
    /// The service rejected this app's client credentials.
    case rejectedApp
    case unreachable
}

struct TrackerSessionMachine<Code: Equatable>: Equatable {
    enum State: Equatable {
        case signedOut
        case requestingCode
        /// The code is on screen, waiting for the user to approve it.
        case awaitingApproval(Code)
        /// The last connect attempt failed; signed out, with a reason to show.
        case failed(TrackerConnectFailure)
        /// Tokens are held. `account` is nil until the identity is known.
        case connected(account: String?)
    }

    enum Event: Equatable {
        case connectRequested
        case codeIssued(Code)
        case connectFailed(TrackerConnectFailure)
        case connectCancelled
        /// Tokens landed: the device flow was approved, or they were restored
        /// at launch or pulled from iCloud. `account` when already known.
        case tokensHeld(account: String?)
        case identityResolved(account: String)
        /// No tokens here any more (never connected, or removed elsewhere).
        case tokensGone
        /// The user disconnected on this device.
        case disconnected
    }

    enum Effect: Equatable {
        case startDeviceFlow
        case cancelDeviceFlow
        /// Look up who the held tokens belong to, retrying until it succeeds
        /// or the session stops needing it.
        case resolveIdentity
    }

    private(set) var state: State = .signedOut

    var isConnecting: Bool {
        switch state {
        case .requestingCode, .awaitingApproval: true
        case .signedOut, .failed, .connected: false
        }
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    var account: String? {
        if case let .connected(account) = state { return account }
        return nil
    }

    var pendingCode: Code? {
        if case let .awaitingApproval(code) = state { return code }
        return nil
    }

    var failure: TrackerConnectFailure? {
        if case let .failed(failure) = state { return failure }
        return nil
    }

    /// Applies `event`. Returns the effects to perform, or nil when the event
    /// doesn't apply in the current state (a late code after a cancel, a name
    /// resolved after a disconnect) and the state is left alone.
    mutating func handle(_ event: Event) -> [Effect]? {
        switch (state, event) {
        case (.signedOut, .connectRequested), (.failed, .connectRequested):
            state = .requestingCode
            return [.startDeviceFlow]

        case let (.requestingCode, .codeIssued(code)), let (.awaitingApproval, .codeIssued(code)):
            state = .awaitingApproval(code)
            return []

        case let (.requestingCode, .connectFailed(failure)), let (.awaitingApproval, .connectFailed(failure)):
            state = .failed(failure)
            return []

        case (.requestingCode, .connectCancelled), (.awaitingApproval, .connectCancelled):
            state = .signedOut
            return [.cancelDeviceFlow]

        case let (_, .tokensHeld(account)):
            // Tokens arriving mid-connect (another device finished first, via
            // iCloud) end the device flow too. A known name is never dropped
            // for an unknown one.
            let known = account ?? self.account
            let wasConnecting = isConnecting
            state = .connected(account: known)
            var effects: [Effect] = wasConnecting ? [.cancelDeviceFlow] : []
            if known == nil { effects.append(.resolveIdentity) }
            return effects

        case let (.connected, .identityResolved(account)):
            state = .connected(account: account)
            return []

        case (.connected, .tokensGone), (.failed, .tokensGone), (.signedOut, .tokensGone):
            // A connect in progress on this device outlives a removal that
            // happened elsewhere; the user is signing in again.
            state = .signedOut
            return []

        case (_, .disconnected):
            let wasConnecting = isConnecting
            state = .signedOut
            return wasConnecting ? [.cancelDeviceFlow] : []

        default:
            return nil
        }
    }
}

// MARK: - Journal names

/// What the diagnostic journal records: the shape of the state, never the
/// device code or the account name.
extension TrackerSessionMachine.State {
    var logName: String {
        switch self {
        case .signedOut: "signedOut"
        case .requestingCode: "requestingCode"
        case .awaitingApproval: "awaitingApproval"
        case let .failed(failure): "failed(\(failure))"
        case let .connected(account): account == nil ? "connected(account pending)" : "connected"
        }
    }
}

extension TrackerSessionMachine.Event {
    var logName: String {
        switch self {
        case .connectRequested: "connectRequested"
        case .codeIssued: "codeIssued"
        case let .connectFailed(failure): "connectFailed(\(failure))"
        case .connectCancelled: "connectCancelled"
        case let .tokensHeld(account): account == nil ? "tokensHeld(account unknown)" : "tokensHeld"
        case .identityResolved: "identityResolved"
        case .tokensGone: "tokensGone"
        case .disconnected: "disconnected"
        }
    }
}
