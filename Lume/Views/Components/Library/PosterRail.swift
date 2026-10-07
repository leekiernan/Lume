import SwiftUI

/// Geometry only: callers keep their typed navigation, menus and focus policy.
struct PosterRail<Destination: Hashable, Content: View>: View {
    let title: Text
    let showAll: Destination?
    var groupsFocus = false
    /// Overrides the role height for landscape cards such as Continue Watching.
    var rowHeight: CGFloat?
    var fitsContentHeight = false
    @ViewBuilder let content: () -> Content
    @Environment(\.posterPresentation) private var presentation

    private var layout: PosterCardMetrics.Layout {
        PosterCardMetrics.layout(for: presentation)
    }

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
                    .padding(.vertical, layout.railVerticalPadding)
            }
            .scrollClipDisabled()
            .fixedSize(horizontal: false, vertical: fitsContentHeight)
            .frame(height: fitsContentHeight ? nil : rowHeight ?? layout.rowHeight)
        }
    }

    @ViewBuilder private var cards: some View {
        if fitsContentHeight {
            // The short Continue Watching rail measures every card up front,
            // so horizontal scrolling cannot change its height. Poster rails
            // retain lazy loading and their fixed artwork geometry.
            HStack(spacing: layout.spacing, content: content)
        } else {
            LazyHStack(spacing: layout.spacing, content: content)
        }
    }
}
