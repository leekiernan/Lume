import Foundation

/// Shared account/profile identity for imports and parked progress. Each
/// provider supplies its own account source; neither lifecycle can cross scopes.
nonisolated struct TrackerScope: Equatable {
    let profileID: UUID?
    let accountID: String?

    static var trakt: Self {
        Self(profileID: ActiveProfileStore.current, accountID: TraktAccountIdentityStore.load()?.scope)
    }

    static var simkl: Self {
        Self(profileID: ActiveProfileStore.current, accountID: SimklAccountIdentityStore.load()?.scope)
    }

    func matches(_ current: Self) -> Bool {
        guard let accountID, !accountID.isEmpty else { return false }
        return self == current
    }
}
