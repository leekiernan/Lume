import SwiftUI

/// Uses the existing platform button treatment, with room for connected trackers.
struct MediaFavoriteButton: View {
    let isFavorite: Bool
    let action: () -> Void

    private var title: LocalizedStringKey {
        isFavorite ? "Remove from Favorites" : "Add to Favorites"
    }

    var body: some View {
        #if os(tvOS)
            Button(action: action) {
                MediaFavoriteGlyph(isFavorite: isFavorite, trackerSize: 26)
                    .font(.system(size: 30, weight: .semibold))
            }
            .buttonStyle(TVGlassButtonStyle(action: .secondary))
            .accessibilityLabel(title)
        #elseif os(iOS)
            Button(action: action) {
                MediaFavoriteGlyph(isFavorite: isFavorite)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .frame(minWidth: 44, minHeight: 44)
                    .glassEffectCompat(.regularInteractive, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
        #else
            Button(action: action) { MediaFavoriteGlyph(isFavorite: isFavorite) }
                .help(Text(title))
                .accessibilityLabel(title)
        #endif
    }
}
