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

    @State private var entries: [HomeListEntry] = []
    @State private var items: [HomeMediaItem] = []
    @State private var pagination = PaginationMachine()

    private let pageSize = 100

    var body: some View {
        CategoryPage(title: selection.title) {
            if items.isEmpty, pagination.isPrepared, !pagination.isLoading {
                ContentUnavailableView(
                    "Nothing Here Yet",
                    systemImage: "rectangle.stack"
                )
                .padding(.top, 40)
            } else {
                PosterGrid {
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
        .task(id: selection.section.token) {
            prepare()
        }
    }

    @ViewBuilder
    private func itemLink(_ item: HomeMediaItem) -> some View {
        switch item {
        case let .movie(movie):
            CatalogPosterLink(item: movie, animationNamespace: animationNamespace) { movie in
                MovieCardView(movie: movie, fillsWidth: true)
            }
        case let .series(series):
            CatalogPosterLink(item: series, animationNamespace: animationNamespace) { series in
                SeriesCardView(series: series, fillsWidth: true)
            }
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
