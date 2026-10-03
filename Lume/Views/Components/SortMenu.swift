//
//  SortMenu.swift
//  Lume
//
//  Content ordering for category and genre grids, not curated area roots.
//

import SwiftUI

// MARK: - Content-Only Sort Menu

struct ContentSortMenu: View {
    @Binding var sortRaw: String

    var body: some View {
        Menu {
            Section("Sort By") {
                ForEach(ContentSortOption.allCases) { option in
                    Button {
                        sortRaw = option.rawValue
                    } label: {
                        Label(option.label, systemImage: option.icon)
                        if option.rawValue == sortRaw {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
    }
}

#Preview("Content Only") {
    ContentSortMenu(sortRaw: .constant(ContentSortOption.playlist.rawValue))
}
