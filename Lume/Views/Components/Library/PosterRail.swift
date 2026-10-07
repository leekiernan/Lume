import SwiftUI

/// Geometry only: callers keep their typed navigation, menus and focus policy.
struct PosterRail<Destination: Hashable, Content: View>: View {
    let title: Text
    let showAll: Destination?
    var groupsFocus = false
    /// Nil lets metadata-bearing cards grow with Dynamic Type.
    var rowHeight: CGFloat? = PosterCardMetrics.rowHeight
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(tvOS)
            if groupsFocus { rail.focusSection() } else { rail }
        #else
            rail
        #endif
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                title.railHeadingStyle()
                Spacer()
                if let showAll {
                    NavigationLink(value: showAll) { Text("Show All").font(.subheadline) }
                }
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                cards
                    .padding(.horizontal)
                    .padding(.vertical, PosterCardMetrics.railVerticalPadding)
            }
            .scrollClipDisabled()
            .fixedSize(horizontal: false, vertical: rowHeight == nil)
            .frame(height: rowHeight)
        }
    }

    @ViewBuilder private var cards: some View {
        if rowHeight == nil {
            // The short Continue Watching rail measures every card up front,
            // so horizontal scrolling cannot change its height. Poster rails
            // retain lazy loading and their fixed artwork geometry.
            HStack(spacing: PosterCardMetrics.railSpacing, content: content)
        } else {
            LazyHStack(spacing: PosterCardMetrics.railSpacing, content: content)
        }
    }
}
