import SwiftUI

extension PosterCardMetrics {
    enum Presentation: CaseIterable {
        case rail, search, grid, detail
    }

    struct Layout: Equatable {
        let width: CGFloat
        let height: CGFloat
        let spacing: CGFloat
        let television: Bool

        /// Clearance for the existing 1.08× TV focus lift.
        var railVerticalPadding: CGFloat {
            television ? 28 : 0
        }

        var rowHeight: CGFloat {
            height + 2 * railVerticalPadding + (television ? 0 : 8)
        }
    }

    /// TV board roles; compact platforms retain their native adaptive geometry.
    /// The explicit platform input also lets iOS unit tests cover the TV policy.
    static func layout(for presentation: Presentation, television: Bool = isTelevision) -> Layout {
        let dimensions: (width: CGFloat, height: CGFloat, spacing: CGFloat) = if television {
            switch presentation {
            case .rail: (250, 375, 50)
            case .search: (200, 300, 40)
            case .grid: (320 * 2 / 3, 320, 28)
            case .detail: (240, 360, 40)
            }
        } else {
            switch presentation {
            case .grid: (100, 150, 16)
            case .rail, .search, .detail: (120, 180, 16)
            }
        }
        return Layout(width: dimensions.width, height: dimensions.height, spacing: dimensions.spacing, television: television)
    }

    #if os(tvOS)
        static let isTelevision = true
    #else
        static let isTelevision = false
    #endif
}

extension EnvironmentValues {
    /// A container supplies the role; cards keep one rendering/recovery owner.
    @Entry var posterPresentation: PosterCardMetrics.Presentation = .rail
}
