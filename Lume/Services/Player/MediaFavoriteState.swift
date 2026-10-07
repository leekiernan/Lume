import Foundation

/// Nil means unavailable; remote membership and the local flag share one heart.
nonisolated struct MediaFavoriteState: Equatable {
    enum Destination: CaseIterable {
        case local, trakt, simkl
    }

    /// Nil leaves that destination untouched, including its metadata/history.
    struct Change: Equatable {
        var local: Bool?
        var trakt: Bool?
        var simkl: Bool?
    }

    let local: Bool
    let trakt: Bool?
    let simkl: Bool?

    var isFavorite: Bool {
        local || trakt == true || simkl == true
    }

    var toggled: Bool {
        !isFavorite
    }

    var traktIntent: Bool? {
        intent(for: trakt)
    }

    var simklIntent: Bool? {
        intent(for: simkl)
    }

    var toggleChange: Change {
        Change(local: toggled, trakt: traktIntent, simkl: simklIntent)
    }

    func membership(in destination: Destination) -> Bool? {
        switch destination {
        case .local: local
        case .trakt: trakt
        case .simkl: simkl
        }
    }

    /// Individual menu actions never copy their choice to another list.
    func change(setting isPresent: Bool, in destination: Destination) -> Change? {
        guard membership(in: destination) != nil else { return nil }
        switch destination {
        case .local: return Change(local: isPresent)
        case .trakt: return Change(trakt: isPresent)
        case .simkl: return Change(simkl: isPresent)
        }
    }

    private func intent(for membership: Bool?) -> Bool? {
        guard let membership else { return nil }
        return toggled || membership ? toggled : nil
    }
}
