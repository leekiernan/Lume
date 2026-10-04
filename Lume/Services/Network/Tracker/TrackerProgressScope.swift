import Foundation

/// Identity of derived progress waiting for episode rows. Provider files remain
/// separate; neither another profile nor another provider account may replay it.
nonisolated struct TrackerProgressScope: Equatable {
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
