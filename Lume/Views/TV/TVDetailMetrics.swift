import SwiftUI

/// Television detail roles, kept available to iOS unit tests without importing
/// the TV-only views. Screens keep their existing navigation and focus owners.
enum TVDetailMetrics {
    enum Hero {
        case film, series

        var titleSize: CGFloat {
            self == .film ? 128 : 104
        }

        var titleKerning: CGFloat {
            self == .film ? -4 : -3
        }
    }

    enum Action {
        /// Existing generic controls in Sports/player overlays.
        case standard
        case play
        case secondary

        var height: CGFloat {
            switch self {
            case .standard: 76
            case .play: 84
            case .secondary: 80
            }
        }

        var cornerRadius: CGFloat {
            self == .standard ? 14 : 16
        }
    }

    static let horizontalInset: CGFloat = 90
    static let sectionSpacing: CGFloat = 56
    static let railSpacing: CGFloat = 40
    static let heroHeight: CGFloat = 900
    static let heroBottomInset: CGFloat = 80

    static let episodeCardWidth: CGFloat = 392
    static let episodeStillHeight: CGFloat = 220
    static let posterCardWidth = PosterCardMetrics.layout(for: .detail, television: true).width
    static let posterCardHeight = PosterCardMetrics.layout(for: .detail, television: true).height
    static let castCardWidth: CGFloat = 150
    static let castAvatar: CGFloat = 132
}
