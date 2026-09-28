//
//  CredentialLinkState.swift
//  Lume
//
//  Whether a missing credential is the user's decision or an accident.
//
//  The Trakt and Simkl authorizations and the parental PIN are carried between
//  devices by `CloudSyncEngine`'s three-way merge: local keychain vs CloudKit
//  mirror vs the shadow baseline. For catalog data "absent locally, unchanged in
//  the cloud" rightly means "deleted here — delete it everywhere". For a keychain
//  item it usually doesn't: a keychain item can vanish without the user doing
//  anything (a restore onto a new device, a keychain reset, a test run in the
//  hosting app), and reading that loss as a disconnect signs every device out.
//
//  So the user's decision is recorded as explicit state instead of being
//  inferred from absence. The explicit Disconnect / remove-PIN paths move the
//  credential to `disconnectedByUser(pendingPush: true)`; the reconcile only
//  treats a missing local value as a deletion in that state, and anything else
//  missing is restored from the cloud. The transitions live in one pure
//  function (`CredentialLinkState.applying(_:)`) so this can grow into a full
//  sign-in state machine without scattering the rules.
//
//  Device-local by design: it lives in the credential backend's defaults, never
//  in CloudKit — it describes what the user did *on this device*.
//

import Foundation

/// The credentials whose removal is synced between devices.
nonisolated enum SyncedCredentialKind: String, CaseIterable {
    case trakt
    case simkl
    /// For the PIN, "disconnect" is the parent turning the PIN off.
    case parentalPIN
}

/// This device's record of the user's intent for one synced credential.
nonisolated enum CredentialLinkState: Codable, Equatable {
    /// No removal decision is outstanding. A missing local credential in this
    /// state was lost, not removed, so the cloud copy is pulled back down.
    case connected
    /// The user explicitly disconnected (or removed the PIN) on this device.
    /// While `pendingPush`, a missing local credential is a deletion to
    /// propagate; once the reconcile has pushed it, the flag clears and the
    /// record only remembers the decision.
    case disconnectedByUser(pendingPush: Bool)

    /// What can happen to a credential's link state.
    enum Event: Equatable {
        /// The explicit Disconnect / remove-PIN action, just before the local
        /// item is deleted.
        case userDisconnected
        /// The local delete that followed `userDisconnected` failed, so the
        /// credential is still here and nothing should be propagated.
        case removalFailed
        /// A credential landed in local storage: a sign-in, a token refresh, a
        /// new PIN, or one pulled from another device.
        case credentialStored
        /// A reconcile pass durably deleted the shared cloud copy.
        case deletionPushed
    }

    /// Whether a missing local credential is a deletion the reconcile must
    /// propagate, rather than a loss to repair from the cloud.
    var removalPendingPush: Bool {
        self == .disconnectedByUser(pendingPush: true)
    }

    /// The pure transition function.
    func applying(_ event: Event) -> CredentialLinkState {
        switch (self, event) {
        case (_, .userDisconnected):
            .disconnectedByUser(pendingPush: true)
        case (_, .removalFailed), (_, .credentialStored):
            .connected
        case (.disconnectedByUser, .deletionPushed):
            .disconnectedByUser(pendingPush: false)
        case (.connected, .deletionPushed):
            .connected
        }
    }
}

/// Persists `CredentialLinkState` per credential in the current
/// `CredentialBackend`'s defaults. `connected` is stored as absence, so a device
/// that never recorded a decision — every device before this existed — reads as
/// `connected`.
nonisolated enum CredentialLinkStateStore {
    private static func key(_ kind: SyncedCredentialKind) -> String {
        "credentials.linkState.\(kind.rawValue).v1"
    }

    static func state(for kind: SyncedCredentialKind) -> CredentialLinkState {
        guard let data = CredentialBackend.current.defaults.data(forKey: key(kind)),
              let state = try? JSONDecoder().decode(CredentialLinkState.self, from: data)
        else { return .connected }
        return state
    }

    /// Applies `event` to the stored state and returns the new state.
    @discardableResult
    static func apply(_ event: CredentialLinkState.Event, to kind: SyncedCredentialKind) -> CredentialLinkState {
        let next = state(for: kind).applying(event)
        let defaults = CredentialBackend.current.defaults
        if next == .connected {
            defaults.removeObject(forKey: key(kind))
        } else if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: key(kind))
        }
        return next
    }
}
