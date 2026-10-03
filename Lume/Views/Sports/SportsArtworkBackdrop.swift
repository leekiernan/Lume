//
//  SportsArtworkBackdrop.swift
//  Lume
//
//  A fixture's picture: the teams' colour wash at once, then the home side's
//  (or the competition's) fan art over it when `SportsArtwork` finds one.
//  Callers lay their own legibility gradient on top.
//

import SwiftUI

struct SportsArtworkBackdrop: View {
    let fixture: SportsFixture
    let size: SportsArtwork.Size
    @State private var url: URL?

    var body: some View {
        ZStack {
            Color(white: 0.08)
            TeamPalette.gradient(home: fixture.homePalette, away: fixture.awayPalette)
        }
        // The picture is an overlay, so it fills whatever space the caller
        // gives and never sizes the backdrop: a `scaledToFill` image reports its
        // overflowing size to layout, and `.clipped()` alone only hides the
        // overflow — on iOS it widened the whole Sports page past the screen.
        .overlay {
            if let url {
                CachedAsyncImage(url: url, maxPixelSize: size == .hero ? 1920 : 640) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Color.clear
                    }
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
        .task(id: fixture.id) {
            url = await SportsArtwork.shared.art(for: fixture, size: size)
        }
    }
}
