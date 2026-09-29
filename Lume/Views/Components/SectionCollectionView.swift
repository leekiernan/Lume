//
//  SectionCollectionView.swift
//  Lume
//
//  Incremental full grid for remote-backed rows. The feed retains the complete
//  lightweight source order, while this view hydrates local catalog models only
//  as the viewer reaches each page.
//

import SwiftData
import SwiftUI

struct SectionCollectionSelection: Hashable {
    let section: HomeSectionRef
    let title: String
}

struct SectionCollectionView: View {
    let selection: SectionCollectionSelection
    let feed: SectionFeed
    var animationNamespace: Namespace.ID?

    @Environment(\.modelContext) private var modelContext
    @State private var entries: [HomeListEntry] = []
    @State private var items: [HomeMediaItem] = []
    @State private var pagination = PaginationMachine()

    private let pageSize = 100
    private let columns = [
        GridItem(.adaptive(minimum: PosterCardMetrics.gridMinimum), spacing: PosterCardMetrics.gridSpacing)
    ]

    var body: some View {
        ScrollView {
            #if os(tvOS)
                Text(selection.title)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 40)
            #endif

            if items.isEmpty, pagination.isPrepared, !pagination.isLoading {
                ContentUnavailableView(
                    "Nothing Here Yet",
                    systemImage: "rectangle.stack"
                )
                .padding(.top, 40)
            } else {
                LazyVGrid(columns: columns, spacing: PosterCardMetrics.gridSpacing) {
                    ForEach(items) { item in
                        itemLink(item)
                            .onAppear {
                                if item.id == items.last?.id { requestNextPage() }
                            }
                    }

                    if pagination.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding()
            }
        }
        .browseActivity()
        #if !os(tvOS)
            .navigationTitle(selection.title)
        #endif
            .task(id: selection.section.token) {
                prepare()
            }
    }

    @ViewBuilder
    private func itemLink(_ item: HomeMediaItem) -> some View {
        switch item {
        case let .movie(movie):
            NavigationLink(value: movie) {
                MovieCardView(movie: movie, fillsWidth: true)
                    .matchedTransitionSourceIfAvailable(id: movie.id, in: animationNamespace)
            }
            .posterCardButtonStyle()
            .mediaFavoriteMenu(
                isFavorite: { movie.isFavorite },
                onToggleFavorite: { MediaFavorites.toggle(movie, in: modelContext) }
            )
        case let .series(series):
            NavigationLink(value: series) {
                SeriesCardView(series: series, fillsWidth: true)
                    .matchedTransitionSourceIfAvailable(id: series.id, in: animationNamespace)
            }
            .posterCardButtonStyle()
            .mediaFavoriteMenu(
                isFavorite: { series.isFavorite },
                onToggleFavorite: { MediaFavorites.toggle(series, in: modelContext) }
            )
        case .live:
            EmptyView()
        }
    }

    private func prepare() {
        guard pagination.prepare(for: selection.section.token) else { return }
        guard let snapshot = feed.collection(for: selection.section) else { return }
        entries = snapshot.entries
        items = snapshot.preview
        pagination.seed(nextOffset: snapshot.nextOffset, canLoadMore: snapshot.hasMoreCandidates)
        if items.isEmpty, pagination.canLoadMore { requestNextPage() }
    }

    private func requestNextPage() {
        guard pagination.canLoadMore, !pagination.isLoading else { return }
        Task { await loadNextPage() }
    }

    private func loadNextPage() async {
        guard let request = pagination.beginLoading() else { return }

        let page = await feed.page(entries: entries, from: request.offset, limit: pageSize)
        guard !Task.isCancelled else {
            pagination.abandon(request)
            return
        }
        guard pagination.finish(
            request,
            scanned: page.nextOffset - request.offset,
            hasMore: page.hasMoreCandidates
        ) else { return }

        var existing = Set(items.map(\.id))
        items.append(contentsOf: page.items.filter { existing.insert($0.id).inserted })
        if page.items.isEmpty, pagination.canLoadMore { requestNextPage() }
    }
}
