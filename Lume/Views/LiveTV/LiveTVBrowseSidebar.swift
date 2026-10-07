//
//  LiveTVBrowseSidebar.swift
//  Lume
//
//  Live TV's browse panel: its virtual sections (Favorites, Recents, …) then
//  the provider's categories, in the shared `BrowseSidebarPanel`.
//

import SwiftUI

struct LiveTVBrowseSidebar: View {
    let state: BrowseSidebarState
    let sections: [LiveTVSection]
    let onSelect: (LiveTVSection) -> Void
    /// Hands focus back to the channel the viewer came from — see
    /// `LiveTVView.returnFromBrowse`.
    var onReturnToContent: (() -> Void)?

    var body: some View {
        BrowseSidebarPanel(
            state: state,
            title: Text("Live TV"),
            sections: panelSections,
            onReturnToContent: onReturnToContent
        )
    }

    private var panelSections: [BrowseSidebarPanel.Section] {
        let virtual = sections.filter(\.isVirtual)
        let categories = sections.filter { !$0.isVirtual }
        var result: [BrowseSidebarPanel.Section] = []
        if !virtual.isEmpty {
            result.append(.init(id: "virtual", rows: virtual.map(row)))
        }
        if !categories.isEmpty {
            result.append(.init(id: "categories", title: "Categories", rows: categories.map(row)))
        }
        return result
    }

    private func row(_ section: LiveTVSection) -> BrowseSidebarPanel.Row {
        BrowseSidebarPanel.Row(
            id: section.id,
            title: section.titleText,
            systemImage: section.icon,
            titleLineLimit: 2,
            action: { onSelect(section) }
        )
    }
}
