//
//  SportsBrowseSidebar.swift
//  Lume
//
//  The Sports hub's browse panel, in the shared `BrowseSidebarPanel` Movies,
//  Series and Live TV use: My Sports, then every follow — teams and leagues
//  in the viewer's order — each narrowing the hub to itself, and Manage Teams
//  at its foot. On tvOS it slides in on a left press from the page's leading
//  edge; elsewhere the toolbar's browse button or the title opens it.
//

import SwiftUI

struct SportsBrowseSidebar: View {
    /// One follow, as the panel lists it.
    struct Entry: Equatable {
        let key: String
        let title: String
        let logoURL: URL?
    }

    @Binding var isPresented: Bool
    let entries: [Entry]
    let scope: SportsHubScope
    let onSelect: (SportsHubScope) -> Void
    let onManageTeams: () -> Void
    /// Hands focus back to where the page had it.
    var onReturnToContent: (() -> Void)?

    private static let allRow = "all"

    var body: some View {
        BrowseSidebarPanel(
            isPresented: $isPresented,
            title: Text("Sports"),
            sections: sections,
            selectedId: selectedId,
            onReturnToContent: onReturnToContent
        )
    }

    private var selectedId: String {
        switch scope {
        case .all: Self.allRow
        case let .follow(key): "follow:\(key)"
        }
    }

    private var sections: [BrowseSidebarPanel.Section] {
        var result = [BrowseSidebarPanel.Section(id: "all", rows: [
            .init(id: Self.allRow, title: Text("My Sports"), systemImage: "sportscourt") { onSelect(.all) }
        ])]
        if !entries.isEmpty {
            result.append(.init(id: "following", title: "Following", rows: entries.map { entry in
                .init(id: "follow:\(entry.key)", title: Text(verbatim: entry.title), imageURL: entry.logoURL) {
                    onSelect(.follow(entry.key))
                }
            }))
        }
        result.append(.init(id: "manage", isSeparated: true, rows: [
            .init(id: "manage", title: Text("Manage Teams"), systemImage: "person.2.badge.plus", action: onManageTeams)
        ]))
        return result
    }
}
