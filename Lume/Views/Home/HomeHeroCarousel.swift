//
//  HomeHeroCarousel.swift
//  Lume
//
//  A Netflix / Apple TV-style hero carousel for the top of a browse page on
//  iOS and macOS — Home, Movies, Series and Sports. (tvOS uses the immersive
//  `TVHomeScreen` instead.) Wide artwork, auto-advancing every few seconds
//  while honouring manual swipes, with the loading-bar page dots centred at
//  the foot. `HeroCarousel` is generic over the slide; each page supplies its
//  artwork and its copy, and `HomeHeroCarousel` is the movies-and-series one.
//
//  The artwork lives in a paging ScrollView (`scrollTargetBehavior(.paging)` +
//  `scrollPosition`) so it works on macOS too. The title / overview / buttons
//  are a FIXED overlay on top (not inside the scroll content) so the copy wraps
//  to the view width instead of the scroll view's unbounded-width proposal.
//

import SwiftData
import SwiftUI

/// The movies-and-series hero of Home, Movies and Series.
struct HomeHeroCarousel: View {
    let items: [HeroItem]

    var body: some View {
        HeroCarousel(
            items: items,
            imageURL: \.imageURL,
            backdrop: { HeroBackdrop(url: $0.imageURL, posterURL: $0.posterURL) },
            info: { HeroInfo(hero: $0, isCompact: $1) },
            managesArtworkComposition: true,
            portraitURL: \.posterURL
        )
    }
}

/// Holds the page geometry steady while its promoted section resolves, using
/// only the last lead backdrop. The real carousel replaces it at the same
/// height once titles and actions are ready.
struct HomeHeroWarmStart: View {
    let backdropURL: URL?
    var posterURL: URL?

    var body: some View {
        HeroCarouselFrame(portraitComposition: true) {
            ZStack(alignment: .bottomLeading) {
                HeroArtworkRegion(managesComposition: true) {
                    HeroBackdrop(url: backdropURL, posterURL: posterURL)
                }
                LinearGradient(
                    colors: [.clear, .black.opacity(0.15), .black.opacity(0.85)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
        }
        .clipped()
    }
}

// MARK: - Preview

#Preview("Multiple Items") {
    let items = [
        HeroItem.movie(
            Movie(id: "preview-hero-1", streamId: 1, name: "The Matrix"),
            backdropURL: URL(string: "https://image.tmdb.org/t/p/w1280/fNG7i7RqM1T0sP1vQmRIqRnW.jpg"),
            logoURL: nil,
            overview: "A computer hacker learns about the true nature of reality."
        ),
        HeroItem.series(
            Series(id: "preview-series-1", seriesId: 1, name: "Breaking Bad", num: 1),
            backdropURL: nil,
            logoURL: nil,
            overview: "A high school chemistry teacher diagnosed with inoperable cancer."
        ),
        HeroItem.movie(
            Movie(id: "preview-hero-2", streamId: 2, name: "Inception"),
            backdropURL: nil,
            logoURL: nil,
            overview: "A thief who steals corporate secrets through dream-sharing technology."
        )
    ]
    HomeHeroCarousel(items: items)
        .modelContainer(previewContainer())
}

#Preview("Single Item") {
    let items = [
        HeroItem.movie(
            Movie(id: "preview-hero-3", streamId: 3, name: "The Dark Knight"),
            backdropURL: nil,
            logoURL: nil,
            overview: "When the menace known as the Joker wreaks havoc on Gotham."
        )
    ]
    HomeHeroCarousel(items: items)
        .modelContainer(previewContainer())
}

#Preview("Empty") {
    HomeHeroCarousel(items: [])
}

// MARK: - Backdrop image

private struct HeroBackdrop: View {
    let url: URL?
    var posterURL: URL?
    @State private var failedPosterURL: URL?

    var body: some View {
        GeometryReader { proxy in
            let poster = HeroArtworkPolicy.portraitURL(posterURL != failedPosterURL ? posterURL : nil, width: proxy.size.width)
            let height = poster == nil ? HeroArtworkPolicy.artworkHeight(width: proxy.size.width, heroHeight: proxy.size.height) : proxy.size.height
            Color.black.overlay(alignment: .top) {
                HeroArtworkImage(
                    url: poster ?? url,
                    sourceRatio: poster == nil ? HeroArtworkPolicy.landscapeRatio : HeroArtworkPolicy.portraitRatio,
                    zoom: poster == nil ? 1 : HeroArtworkPolicy.portraitZoom,
                    onFailure: { if let poster { failedPosterURL = poster } }
                )
                .frame(height: height)
                .mask { CompactHeroArtworkMask(width: proxy.size.width) }
            }
        }
    }
}
