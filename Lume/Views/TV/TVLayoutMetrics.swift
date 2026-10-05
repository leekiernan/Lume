import CoreGraphics

/// Shared edges, not a universal layout grid. Screen content and modal
/// overscan margins deliberately remain separate roles.
nonisolated enum TVLayoutMetrics {
    static let contentInset: CGFloat = 60
    static let modalHorizontalInset: CGFloat = 90
    static let modalVerticalInset: CGFloat = 60
}
