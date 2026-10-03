//
//  TVSportsMetrics.swift
//  Lume
//
//  The tvOS Sports hub's shared measurements, so its hero, header, row
//  headings and rows can't drift apart. Hub only: follow pages use the
//  `CategoryPage` system inset like Movies, and Manage Teams follows Settings.
//

#if os(tvOS)

    import CoreGraphics

    enum TVSportsMetrics {
        /// Where the hub's content starts: hero copy, header, row headings and
        /// the first card of every row line up on it.
        static let railInset: CGFloat = 60
        /// Clear of the tab bar, which the full-bleed hub sits under.
        static let contentTop: CGFloat = 110
        /// Between fixture cards in a row.
        static let railSpacing: CGFloat = 24
        /// Between the taller Big This Week cards.
        static let tallRailSpacing: CGFloat = 32
        /// The side padding inside a whole-screen action's label (Manage Teams,
        /// Unlock Sports Hub, Follow Your Teams).
        static let actionLabelInset: CGFloat = 44
    }

#endif
