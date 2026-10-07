import Foundation

/// Nil means disconnected; remote membership and the local flag share one heart.
nonisolated struct MediaFavoriteState: Equatable {
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

    private func intent(for membership: Bool?) -> Bool? {
        guard let membership else { return nil }
        return toggled || membership ? toggled : nil
    }
}
