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
    @State private var cursor = 0
    @State private var canLoadMore = false
    @State private var isLoading = false
    @State private var isPrepared = false
    @State private var pageRequest = 0

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

            if items.isEmpty, isPrepared, !isLoading {
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

                    if isLoading {
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
            .task {
                prepare()
            }
            .task(id: pageRequest) {
                guard pageRequest > 0 else { return }
                await loadNextPage()
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
        guard !isPrepared else { return }
        isPrepared = true
        guard let snapshot = feed.collection(for: selection.section) else { return }
        entries = snapshot.entries
        items = snapshot.preview
        cursor = snapshot.nextOffset
        canLoadMore = snapshot.hasMoreCandidates
        if items.isEmpty, canLoadMore { requestNextPage() }
    }

    private func requestNextPage() {
        guard canLoadMore, !isLoading else { return }
        pageRequest &+= 1
    }

    private func loadNextPage() async {
        guard canLoadMore, !isLoading else { return }
        isLoading = true

        let page = await feed.page(entries: entries, from: cursor, limit: pageSize)
        guard !Task.isCancelled else {
            isLoading = false
            return
        }
        cursor = page.nextOffset
        canLoadMore = page.hasMoreCandidates

        var existing = Set(items.map(\.id))
        items.append(contentsOf: page.items.filter { existing.insert($0.id).inserted })
        isLoading = false
        if page.items.isEmpty, canLoadMore { requestNextPage() }
    }
}
