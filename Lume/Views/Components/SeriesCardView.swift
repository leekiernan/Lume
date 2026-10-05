//
//  SeriesCardView.swift
//  Lume
//
//  Card view for displaying a series cover and title
//

import SwiftUI

struct SeriesCardView: View {
    let series: Series
    /// Set by the category / genre grids so the card sizes to its cell rather
    /// than the fixed rail width — see `View.posterArtworkFrame(fillsWidth:)`.
    var fillsWidth: Bool = false

    var body: some View {
        posterCard
    }

    var posterCard: PosterCard {
        PosterCard(title: series.name, provider: series.cover, posterPath: series.posterPath,
                   request: .init(kind: .series, id: series.id, categoryID: series.categoryId),
                   fallbackSymbol: "tv", fillsWidth: fillsWidth)
    }
}

#Preview("Basic") {
    SeriesCardView(
        series: Series(
            id: "preview-1",
            seriesId: 1,
            name: "Sample Series"
        )
    )
}

#Preview("With Cover") {
    SeriesCardView(
        series: Series(
            id: "preview-2",
            seriesId: 2,
            name: "Breaking Bad",
            cover: "https://image.tmdb.org/t/p/w185/ggFHVNu6YYI5L9T5f7jFpBZdXl.jpg",
            rating: "9.5"
        )
    )
}

#Preview("With TMDB") {
    let series = Series(
        id: "preview-3",
        seriesId: 3,
        name: "Stranger Things",
        cover: "https://image.tmdb.org/t/p/w185/49WJfeN0m4b6B1JYbMqG0Y6j6aM.jpg",
        rating: "8.7"
    )
    series.tmdbId = 66732
    series.contentRating = "TV-14"
    return SeriesCardView(series: series)
}
