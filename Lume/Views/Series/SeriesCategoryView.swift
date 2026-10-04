//
//  SeriesCategoryView.swift
//  Lume
//
//  The concrete Series category screens — the full "Show All" grid and the
//  home-screen preview row — built on the shared components in
//  CategoryContentGrid.swift.
//

import SwiftData
import SwiftUI

// MARK: - Series Category View

typealias SeriesCategoryView = CatalogCategoryView<SeriesCatalog>

#Preview("Series Category Grid") {
    let container = previewContainer()
    let categories = (try? container.mainContext.fetch(FetchDescriptor<Category>())) ?? []
    let category = categories.first { $0.typeRaw == "series" } ?? categories[0]
    return NavigationStack {
        SeriesCategoryView(category: category, animationNamespace: nil)
    }
    .modelContainer(container)
}

#Preview("Series Category Empty") {
    let container = previewContainer()
    let emptyCategory = Category(apiId: "998", name: "Empty Series", parentId: 0, type: .series, playlist: PreviewData.samplePlaylist)
    return NavigationStack {
        SeriesCategoryView(category: emptyCategory, animationNamespace: nil)
    }
    .modelContainer(container)
}
