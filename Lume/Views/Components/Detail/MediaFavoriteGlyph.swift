import SwiftUI

/// One heart state; connected tracker marks describe where the action syncs.
/// Only the heart fills. Shared by detail actions and every player overlay.
struct MediaFavoriteGlyph: View {
    let isFavorite: Bool
    var showTrackers = true
    var trackerSize: CGFloat = 16

    private var trakt: Bool {
        showTrackers && TraktService.shared.isConnected
    }

    private var simkl: Bool {
        showTrackers && SimklService.shared.isConnected
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .symbolReplaceTransition(value: isFavorite)
            if trakt { tracker("TraktMark") }
            if simkl { tracker("SimklMark") }
        }
        .accessibilityElement(children: .ignore)
        .task(id: "\(TraktService.shared.mutations.account ?? "")|\(SimklService.shared.mutations.account ?? "")") {
            guard showTrackers else { return }
            async let trakt: Void = TraktService.shared.refreshWatchlistIfNeeded()
            async let simkl: Void = SimklService.shared.refreshWatchlistIfNeeded()
            _ = await (trakt, simkl)
        }
    }

    private func tracker(_ asset: String) -> some View {
        Image(asset)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: trackerSize, height: trackerSize)
    }
}
