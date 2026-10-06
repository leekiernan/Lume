import SwiftUI

/// Rendering only: callers retain their model observation, navigation, menus
/// and resume lookup. PosterArtworkView still owns metadata recovery.
///
/// The poster carries the title — it almost always prints it — so the card
/// shows no caption. Until the poster arrives (or when there is none) the
/// title sits inside a coloured tile instead.
struct PosterCard: View {
    let title: String
    let provider: String?
    var posterPath: String?
    var request: PosterArtworkRequest?
    var fillsWidth = false
    var progress: Double?
    var badge: String?

    var body: some View {
        PosterArtworkView(
            provider: provider, posterPath: posterPath, request: request,
            maxPixelSize: PosterCardMetrics.posterHeight
        ) { phase in
            PosterArtworkContent(phase: phase, title: title)
        }
        .posterArtworkFrame(fillsWidth: fillsWidth)
        .overlay {
            if let progress {
                ArtworkProgressBar(fraction: progress)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: PosterCardMetrics.cornerRadius, style: .continuous))
        .posterBadge(badge)
        // A post-clip shadow costs an offscreen pass on tvOS, where the
        // existing card button style supplies the focus depth instead.
        #if !os(tvOS)
            .shadow(radius: 2)
        #endif
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
    }
}

/// Shared image-phase rendering: the poster once it loads, the title tile
/// while it loads or when it fails.
struct PosterArtworkContent: View {
    let phase: AsyncImagePhase
    let title: String

    var body: some View {
        switch phase {
        case let .success(image):
            image.resizable().aspectRatio(contentMode: .fill)
        case .empty, .failure:
            PosterTitleTile(title: title)
        @unknown default:
            EmptyView()
        }
    }
}

/// A poster's stand-in: the title, bottom leading, on one of the brand's
/// unloaded-card colours — chosen from the title so a card keeps its colour
/// across launches and rails.
struct PosterTitleTile: View {
    let title: String

    var body: some View {
        Rectangle()
            .fill(Self.color(for: title))
            .overlay(alignment: .bottomLeading) {
                Text(title)
                    .font(PosterCardMetrics.tileTitleFont)
                    .foregroundStyle(.white)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .padding(PosterCardMetrics.tileInset)
            }
    }

    /// The redesign's placeholder tiles (violet, slate, rust, moss, olive,
    /// indigo, plum, teal): dark enough for white text in either appearance.
    static let palette: [Color] = [0x3A2A52, 0x1F3B52, 0x523028, 0x24493C, 0x4D4424, 0x2C3060, 0x4A2748, 0x20464A]
        .map { Color(red: Double($0 >> 16 & 0xFF) / 255, green: Double($0 >> 8 & 0xFF) / 255, blue: Double($0 & 0xFF) / 255) }

    /// Stable across launches (unlike `hashValue`): FNV-1a over the scalars.
    static func paletteIndex(for title: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for scalar in title.unicodeScalars {
            hash = (hash ^ scalar.value) &* 16_777_619
        }
        return Int(hash % UInt32(palette.count))
    }

    static func color(for title: String) -> Color {
        palette[paletteIndex(for: title)]
    }
}
