//
//  SearchResultsView.swift
//  Lume
//
//  How a settled search is laid out:
//
//  - No filter: Now Playing and Coming Up as channel lists — the Live TV
//    list's own rows, with each channel's category — showing the first few
//    with "Show All", then Movies and Series as poster rails whose "Show All"
//    opens the same grid every other rail does.
//  - A filter: that type in full, inline — a poster grid like a category
//    view, or both channel lists for Live TV. Text and type have already
//    narrowed it as far as it goes, so nothing hides behind "Show All".
//  - One section's "Show All": that section in full.
//

import SwiftData
import SwiftUI

/// Which of the layouts above to show.
enum SearchResultsLayout: Equatable {
    case overview
    case filtered(ContentFilter)
    case section(SearchSection)
}

struct SearchResultsView<Header: View>: View {
    let results: SearchResults
    let layout: SearchResultsLayout
    /// Now/next for the Now Playing channels, by guide channel id.
    let epgByChannel: [String: ChannelEPG]
    /// What each channel's category label reads, by stream id.
    let channelLabels: [String: String]
    let animationNamespace: Namespace.ID
    let onPlay: (LiveStream) -> Void
    /// Scrolls with the results — the filter bar. Pinned outside the scroll
    /// view, it stayed mid-screen once tvOS scrolled the search field away,
    /// and the results were squeezed into what was left below it.
    @ViewBuilder var header: () -> Header

    @Environment(\.modelContext) private var modelContext

    /// How many channels a list shows before "Show All", with no filter.
    static var channelPreviewCount: Int {
        5
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                header()
                switch layout {
                case .overview:
                    nowPlaying(limit: Self.channelPreviewCount)
                    upcoming(limit: Self.channelPreviewCount)
                    movieRail
                    seriesRail
                case .filtered(.movies), .section(.movies):
                    grid(results.movies) { MovieCardView(movie: $0, fillsWidth: true) }
                case .filtered(.series), .section(.series):
                    grid(results.series) { SeriesCardView(series: $0, fillsWidth: true) }
                case .filtered(.liveTV), .filtered(.all):
                    nowPlaying(limit: nil)
                    upcoming(limit: nil)
                case .section(.nowPlaying):
                    nowPlaying(limit: nil)
                case .section(.upcoming):
                    upcoming(limit: nil)
                }
            }
            .padding(.vertical)
        }
        .scrollDismissesKeyboardIfAvailable()
    }

    // MARK: - Channels

    private func nowPlaying(limit: Int?) -> some View {
        channelSection("Now Playing", rows: results.nowPlaying, limit: limit, showAll: .nowPlaying) { stream in
            channelRow(stream, upcoming: nil)
        }
    }

    private func upcoming(limit: Int?) -> some View {
        channelSection("Coming Up", rows: results.upcoming, limit: limit, showAll: .upcoming) { programme in
            channelRow(programme.stream, upcoming: programme.slot)
        }
    }

    @ViewBuilder
    private func channelSection<Row: Identifiable>(
        _ title: LocalizedStringKey,
        rows: [Row],
        limit: Int?,
        showAll: SearchSection,
        @ViewBuilder row: @escaping (Row) -> some View
    ) -> some View {
        if !rows.isEmpty {
            let shown = limit.map { Array(rows.prefix($0)) } ?? rows
            VStack(alignment: .leading, spacing: 12) {
                header(title, showAll: shown.count < rows.count ? showAll : nil)
                VStack(spacing: channelSpacing) {
                    ForEach(shown) { item in
                        row(item)
                        #if !os(tvOS)
                            Divider().padding(.leading, 88)
                        #endif
                    }
                }
                #if os(tvOS)
                .padding(.horizontal, 60)
                #endif
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    @ViewBuilder
    private func channelRow(_ stream: LiveStream, upcoming: EPGSlot?) -> some View {
        let epg = upcoming == nil ? epgByChannel[stream.epgChannelId ?? ""] : nil
        #if os(tvOS)
            TVChannelRow(
                stream: stream, epg: epg, categoryName: channelLabels[stream.id], upcoming: upcoming,
                onPlay: { onPlay(stream) }
            )
        #else
            Button {
                onPlay(stream)
            } label: {
                LiveStreamCardView(stream: stream, epg: epg, categoryName: channelLabels[stream.id], upcoming: upcoming)
                    .padding(.horizontal)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .liveChannelMenu(
                isFavorite: stream.isFavorite,
                onToggleFavorite: { LiveChannelFavorites.toggle(stream, in: modelContext) }
            )
        #endif
    }

    private var channelSpacing: CGFloat {
        #if os(tvOS)
            14
        #else
            0
        #endif
    }

    // MARK: - Movies and series

    @ViewBuilder
    private var movieRail: some View {
        if !results.movies.isEmpty {
            CollectionPreviewRow(
                title: "Movies",
                showAll: SearchSection.movies,
                items: Array(results.movies.prefix(collectionPreviewLimit)),
                hasMore: results.movies.count > collectionPreviewLimit,
                animationNamespace: animationNamespace,
                card: { MovieCardView(movie: $0) }
            )
        }
    }

    @ViewBuilder
    private var seriesRail: some View {
        if !results.series.isEmpty {
            CollectionPreviewRow(
                title: "Series",
                showAll: SearchSection.series,
                items: Array(results.series.prefix(collectionPreviewLimit)),
                hasMore: results.series.count > collectionPreviewLimit,
                animationNamespace: animationNamespace,
                card: { SeriesCardView(series: $0) }
            )
        }
    }

    /// Posters inline, laid out like a category view.
    private func grid<Item: Identifiable & Hashable & WatchlistFavoritable>(
        _ items: [Item],
        @ViewBuilder card: @escaping (Item) -> some View
    ) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: PosterCardMetrics.gridMinimum), spacing: PosterCardMetrics.gridSpacing)],
            spacing: PosterCardMetrics.gridSpacing
        ) {
            ForEach(items) { item in
                NavigationLink(value: item) {
                    card(item)
                        .matchedTransitionSourceIfAvailable(id: item.id, in: animationNamespace)
                }
                .posterCardButtonStyle()
                .mediaFavoriteMenu(
                    isFavorite: { item.isFavorite },
                    onToggleFavorite: { MediaFavorites.toggle(item, in: modelContext) }
                )
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Header

    private func header(_ title: LocalizedStringKey, showAll: SearchSection?) -> some View {
        HStack {
            Text(title)
                .font(PosterCardMetrics.railTitleFont)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
            Spacer()
            if let showAll {
                NavigationLink(value: showAll) {
                    Text("Show All")
                        .font(.subheadline)
                }
            }
        }
        .padding(.horizontal)
    }
}

private extension View {
    @ViewBuilder
    func scrollDismissesKeyboardIfAvailable() -> some View {
        #if os(iOS)
            scrollDismissesKeyboard(.immediately)
        #else
            self
        #endif
    }
}
