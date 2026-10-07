//
//  PosterCardMetrics.swift
//  Lume
//
//  Shared sizing for the poster cards used across the Home, Movies and Series
//  browse rows. tvOS needs noticeably larger cards, wider rail spacing and room
//  for the focus lift so titles and artwork never bleed into neighbouring cards
//  on the 10-foot UI; iOS keeps the compact phone-sized layout.
//

import SwiftUI

enum PosterCardMetrics {
    static let posterWidth = layout(for: .rail).width
    static let posterHeight = layout(for: .rail).height
    static let railSpacing = layout(for: .rail).spacing
    static let railVerticalPadding = layout(for: .rail).railVerticalPadding
    static let rowHeight = layout(for: .rail).rowHeight
    static let gridMinimum = layout(for: .grid).width
    static let gridSpacing = layout(for: .grid).spacing

    #if os(tvOS)
        static let cornerRadius: CGFloat = 16
        /// The title inside an unloaded card's tile.
        static let tileTitleFont: Font = .system(size: 24, weight: .bold)
        static let tileInset: CGFloat = 20

        /// Inset between a transparent channel logo and its card plate.
        static let liveLogoInset: CGFloat = 32
    #else
        static let cornerRadius: CGFloat = 8
        static let tileTitleFont: Font = .caption.weight(.bold)
        static let tileInset: CGFloat = 10

        static let liveLogoInset: CGFloat = 16
    #endif

    /// Poster proportions, used to derive a card's height from a grid cell's
    /// width so grid artwork keeps the same shape as the rails' fixed cards.
    static let posterAspectRatio: CGFloat = posterWidth / posterHeight

    // MARK: - Section surfaces

    // Home, Movies and Series are all built from the same rails, so their
    // rhythm is defined once here. Home used a smaller header and no top inset
    // while the library pages used a larger one and padded both ends, which
    // read as two different screens for what is the same layout.

    /// The header above a browse rail. One treatment everywhere.
    static let railTitleFont: Font = .headline

    /// Vertical gap between rails. `TVHomeMetrics.rowSpacing` derives from this
    /// — the tvOS fold's peek height is measured against it.
    static let sectionSpacing: CGFloat = 28

    // Inset above the first rail and below the last. The tvOS hero replaces
    // the top inset when it is showing, since it fills that space itself.
    #if os(tvOS)
        static let sectionVerticalPadding: CGFloat = 60
    #else
        static let sectionVerticalPadding: CGFloat = 16
    #endif
}

extension View {
    /// Sizes a poster card's artwork.
    ///
    /// Rails lay cards out at their presentation role's fixed width; category and genre
    /// grids pass `fillsWidth: true` so the card takes its cell's width instead.
    /// An `.adaptive` column is only guaranteed to be *at least* `gridMinimum`
    /// wide, so on a wide window (macOS especially) a fixed-width card overflows
    /// its narrower cell, swallows `gridSpacing` and leaves the posters sitting
    /// flush against each other. Filling the cell keeps the gap exactly
    /// `gridSpacing`, independent of the rail roles.
    ///
    /// Every branch ends in `.contentShape(Rectangle())`, and that is
    /// load-bearing rather than cosmetic. Card artwork is drawn with
    /// `.aspectRatio(contentMode: .fill)`, so a source image that is not
    /// poster-shaped overflows this frame — a 16:9 still in a 120×180 box
    /// lays out 320 wide. Clipping (the caller's `clipShape`, or `.clipped()`)
    /// hides that overhang but leaves the *hit region* at the full 320, so the
    /// wide card sits invisibly on top of its neighbour and swallows its taps:
    /// tapping one poster opens the other. Only an explicit content shape
    /// pins the tap target to the frame. Media servers make this routine —
    /// Jellyfin, Emby and Plex all serve a generated widescreen thumbnail
    /// when a title has no real poster.
    @ViewBuilder
    func posterArtworkFrame(fillsWidth: Bool, presentation: PosterCardMetrics.Presentation = .rail) -> some View {
        let layout = PosterCardMetrics.layout(for: presentation)
        if fillsWidth {
            // A grid cell proposes a definite width and no height, which
            // `.fit` resolves into the matching 2:3 height; the artwork then
            // fills that box as an overlay and the caller's clip shape trims
            // the overhang.
            Color.clear
                .aspectRatio(PosterCardMetrics.posterAspectRatio, contentMode: .fit)
                .overlay { self }
                .contentShape(Rectangle())
        } else {
            frame(width: layout.width, height: layout.height)
                .contentShape(Rectangle())
        }
    }

    /// Width for a poster card's title line, matching `posterArtworkFrame`.
    @ViewBuilder
    func posterTitleFrame(fillsWidth: Bool, presentation: PosterCardMetrics.Presentation = .rail) -> some View {
        if fillsWidth {
            frame(maxWidth: .infinity, alignment: .leading)
        } else {
            frame(width: PosterCardMetrics.layout(for: presentation).width, alignment: .leading)
        }
    }

    /// Applies the focus-aware card button style on tvOS (scale + shadow on
    /// focus) and the plain style elsewhere, so browse cards lift cleanly
    /// without overlapping neighbours.
    @ViewBuilder
    func posterCardButtonStyle() -> some View {
        #if os(tvOS)
            buttonStyle(TVCardButtonStyle(focusScale: 1.08))
        #else
            buttonStyle(.plain)
        #endif
    }
}
