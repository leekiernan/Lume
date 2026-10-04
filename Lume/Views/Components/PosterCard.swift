import SwiftUI

/// Rendering only: callers retain their model observation, navigation, menus
/// and resume lookup. PosterArtworkView still owns metadata recovery.
struct PosterCard: View {
    let title: String
    let provider: String?
    var posterPath: String?
    var request: PosterArtworkRequest?
    var fallbackSymbol = "film"
    var fillsWidth = false
    var progress: Double?
    var badge: String?

    var body: some View {
        VStack(alignment: .leading, spacing: PosterCardMetrics.titleSpacing) {
            PosterArtworkView(
                provider: provider, posterPath: posterPath, request: request,
                maxPixelSize: PosterCardMetrics.posterHeight
            ) { phase in
                PosterArtworkContent(phase: phase, fallbackSymbol: fallbackSymbol)
            }
            .posterArtworkFrame(fillsWidth: fillsWidth)
            .overlay(alignment: .bottomLeading) {
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.lumeAccent)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: PosterCardMetrics.cornerRadius))
            .posterBadge(badge)
            // A post-clip shadow costs an offscreen pass on tvOS, where the
            // existing card button style supplies the focus depth instead.
            #if !os(tvOS)
                .shadow(radius: 2)
            #endif

            Text(title)
                .font(PosterCardMetrics.titleFont)
                .lineLimit(2)
                .posterTitleFrame(fillsWidth: fillsWidth)
        }
    }
}

/// Shared image-phase rendering. Detail tvOS cards retain their different
/// plate/symbol treatment and geometry; live logos do not use this component.
struct PosterArtworkContent: View {
    let phase: AsyncImagePhase
    let fallbackSymbol: String
    var placeholderFill: Color = .gray.opacity(0.3)
    var fallbackForeground: Color = .secondary
    var fallbackFont: Font = .largeTitle

    var body: some View {
        switch phase {
        case .empty:
            Rectangle().fill(placeholderFill).overlay { ProgressView() }
        case let .success(image):
            image.resizable().aspectRatio(contentMode: .fill)
        case .failure:
            Rectangle().fill(placeholderFill).overlay {
                Image(systemName: fallbackSymbol)
                    .foregroundStyle(fallbackForeground)
                    .font(fallbackFont)
            }
        @unknown default:
            EmptyView()
        }
    }
}
