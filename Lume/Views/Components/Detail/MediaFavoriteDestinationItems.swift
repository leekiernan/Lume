import SwiftData
import SwiftUI

/// Native checked menu items for independent membership. The main heart still
/// uses the combined toggle; every detail/player/card uses these same items.
struct MediaFavoriteDestinationItems: View {
    let model: any WatchlistFavoritable
    let context: ModelContext
    var onChange: () -> Void = {}

    var body: some View {
        let state = MediaFavorites.state(model)
        Toggle(isOn: binding(for: .local, membership: state.local)) {
            Label("Local Favorites", systemImage: "heart")
        }
        if let trakt = state.trakt {
            Toggle(isOn: binding(for: .trakt, membership: trakt)) {
                Label("Trakt", image: "TraktMark")
            }
        }
        if let simkl = state.simkl {
            Toggle(isOn: binding(for: .simkl, membership: simkl)) {
                Label("Simkl", image: "SimklMark")
            }
        }
    }

    private func binding(for destination: MediaFavoriteState.Destination, membership: Bool) -> Binding<Bool> {
        Binding(get: { membership }, set: {
            MediaFavorites.set($0, in: destination, for: model, context: context)
            onChange()
        })
    }
}

extension View {
    /// Resolve inside the native menu builder, not during each player clock tick.
    func playerFavoriteDestinationsMenu(for ref: PlayableMedia.ContentRef, in context: ModelContext,
                                        onChange: @escaping () -> Void) -> some View
    {
        contextMenu {
            if let model = PlayerFavorites.watchlistModel(for: ref, in: context) {
                MediaFavoriteDestinationItems(model: model, context: context, onChange: onChange)
            }
        }
    }
}
