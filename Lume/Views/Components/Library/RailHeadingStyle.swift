import SwiftUI

extension View {
    /// Shared label treatment; the rail keeps its own navigation and focus.
    func railHeadingStyle() -> some View {
        font(PosterCardMetrics.railTitleFont)
            .fontWeight(.bold)
            .foregroundStyle(.primary)
    }
}
