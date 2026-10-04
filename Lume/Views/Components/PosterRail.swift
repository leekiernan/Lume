import SwiftUI

/// Geometry only: callers keep their typed navigation, menus and focus policy.
struct PosterRail<Destination: Hashable, Content: View>: View {
    let title: Text
    let showAll: Destination?
    var groupsFocus = false
    var rowHeight: CGFloat = PosterCardMetrics.rowHeight
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
                title.font(PosterCardMetrics.railTitleFont).fontWeight(.bold).foregroundStyle(.secondary)
                Spacer()
                if let showAll {
                    NavigationLink(value: showAll) { Text("Show All").font(.subheadline) }
                }
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: PosterCardMetrics.railSpacing, content: content)
                    .padding(.horizontal)
                    .padding(.vertical, PosterCardMetrics.railVerticalPadding)
            }
            .scrollClipDisabled()
            .frame(height: rowHeight)
        }
    }
}
