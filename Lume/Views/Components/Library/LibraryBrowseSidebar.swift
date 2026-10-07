//
//  LibraryBrowseSidebar.swift
//  Lume
//
//  The provider's own categories, demoted from the Movies/Series landing screen
//  to a sidebar that slides in over it. Hidden by default: the configurable
//  rows (`LibrarySectionsView`) are the page now, and this is how you reach the
//  raw catalog.
//
//  Drawn by the shared `BrowseSidebarPanel`. Picking a category doesn't
//  filter the page behind: it navigates to that category's own full grid,
//  which is why the rows hand their selection back to the caller rather than
//  pushing themselves.
//

import SwiftData
import SwiftUI

struct LibraryBrowseSidebar: View {
    let state: BrowseSidebarState
    let categories: [Category]
    let genres: [String]
    let type: CategoryType
    let onSelectCategory: (Category) -> Void
    let onSelectGenre: (String) -> Void

    var body: some View {
        // The app's own term for the type, so the panel header matches the
        // tab, Content Management and everywhere else.
        BrowseSidebarPanel(state: state, title: Text(type.localizedLabel), sections: panelSections)
    }

    private var panelSections: [BrowseSidebarPanel.Section] {
        var result = [BrowseSidebarPanel.Section(
            id: "categories",
            rows: categories.map { category in
                .init(id: "category:\(category.id)", title: Text(verbatim: category.name)) { onSelectCategory(category) }
            }
        )]
        if !genres.isEmpty {
            result.append(.init(
                id: "genres",
                title: "Browse by Genre",
                rows: genres.map { genre in
                    .init(id: "genre:\(genre)", title: Text(verbatim: genre)) { onSelectGenre(genre) }
                }
            ))
        }
        return result
    }
}

// MARK: - Query

/// The categories the sidebar lists: one type, in the active playlist, minus
/// the viewer's hidden and restricted ones — all selected in SQL, so a page
/// never fetches every playlist's categories to filter them on each body pass.
/// Internal so the tests can run it against a real store.
enum LibraryCategoryQuery {
    static func descriptor(
        type: CategoryType,
        playlistPrefix prefix: String,
        excludedCategoryIDs excluded: Set<String>
    ) -> FetchDescriptor<Category> {
        let typeRaw = type.rawValue
        let filtersCategories = !excluded.isEmpty
        return FetchDescriptor<Category>(predicate: #Predicate {
            $0.typeRaw == typeRaw
                && $0.isHidden == false
                && $0.id.starts(with: prefix)
                && (!filtersCategories || !excluded.contains($0.id))
        })
    }
}
