//
//  CategoryContentGrid.swift
//  Lume
//
//  Shared grid and preview-row components used by both Movies and Series
//  category views, minimising duplication between the two.
//

import SwiftData
import SwiftUI

// MARK: - Full Category Content Grid ("Show All")

struct CategoryContentGrid<Item: Identifiable & Hashable & WatchlistFavoritable, Card: View>: View {
    let title: String
    let items: [Item]
    let animationNamespace: Namespace.ID?
    let emptyTitle: LocalizedStringKey
    let emptyIcon: String
    let emptyDescription: LocalizedStringKey
    var isLoading = false
    /// Called when the last item appears, so a paginating caller can fetch the
    /// next page. Nil callers load their full set up front (unchanged behavior).
    var onLoadMore: (() -> Void)?
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        CategoryPage(title: title) {
            switch CollectionGridPresentation.resolve(hasItems: !items.isEmpty, isLoading: isLoading) {
            case .loading:
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            case .empty:
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptyIcon,
                    description: Text(emptyDescription)
                )
                .padding(.top, 40)
            case .content:
                PosterGrid {
                    ForEach(items) { item in
                        CatalogPosterLink(item: item, animationNamespace: animationNamespace, card: card)
                            .onAppear {
                                if let onLoadMore, item.id == items.last?.id { onLoadMore() }
                            }
                    }
                }
                .padding()
            }
        }
    }
}

// MARK: - Category page

/// The frame every category-style page shares — a Movies or Series category,
/// a Sports team or league: one scrolling page, titled by the navigation bar,
/// or on tvOS (which suppresses that title) by a leading heading in the
/// content. Callers supply what sits under it.
struct CategoryPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            // tvOS suppresses the system navigation title (it renders centred and
            // the tab bar only shows the section, not the category), so we surface
            // the category name as a leading-aligned heading in the content itself.
            #if os(tvOS)
                Text(title)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 40)
            #endif

            content()
        }
        .browseActivity()
        #if !os(tvOS)
            .navigationTitle(title)
            .macNavigationBack()
        #endif
    }
}

// MARK: - Movie Category View

typealias MovieCategoryView = CatalogCategoryView<MovieCatalog>

// MARK: - Previews

#Preview("Movie Category Grid") {
    let container = previewContainer()
    let categories = (try? container.mainContext.fetch(FetchDescriptor<Category>())) ?? []
    let category = categories.first { $0.typeRaw == "vod" } ?? categories[0]
    return NavigationStack {
        MovieCategoryView(category: category, animationNamespace: nil)
    }
    .modelContainer(container)
}

#Preview("Movie Category Empty") {
    let container = previewContainer()
    let emptyCategory = Category(apiId: "999", name: "Empty Category", parentId: 0, type: .vod, playlist: PreviewData.samplePlaylist)
    return NavigationStack {
        MovieCategoryView(category: emptyCategory, animationNamespace: nil)
    }
    .modelContainer(container)
}
