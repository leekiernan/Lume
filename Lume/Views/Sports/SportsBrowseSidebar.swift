//
//  SportsBrowseSidebar.swift
//  Lume
//
//  The Sports hub's browse panel, in the shared `BrowseSidebarPanel` Movies,
//  Series and Live TV use: the followed teams and the followed leagues, each
//  group in the viewer's order and each row opening that follow's own page,
//  and Manage Teams at its foot. On tvOS it slides in
//  on a left press from the page's leading edge; elsewhere the toolbar's
//  browse button opens it.
//

import SwiftUI

struct SportsBrowseSidebar: View {
    /// One follow, as the panel lists it.
    struct Entry: Equatable {
        let key: String
        let title: String
        let logoURL: URL?
        /// A team (or, later, a driver or player) rather than a competition.
        var isTeam = false
    }

    let state: BrowseSidebarState
    let entries: [Entry]
    /// The follow picked: its key.
    let onSelect: (String) -> Void
    let onManageTeams: () -> Void
    /// Hands focus back to where the page had it.
    var onReturnToContent: (() -> Void)?

    var body: some View {
        BrowseSidebarPanel(
            state: state,
            title: Text("Sports"),
            sections: sections,
            onReturnToContent: onReturnToContent
        )
    }

    /// No row for the hub itself: the panel only opens there, and every row
    /// opens a page of its own.
    private var sections: [BrowseSidebarPanel.Section] {
        var result: [BrowseSidebarPanel.Section] = []
        // Teams and competitions apart, each in the viewer's own order.
        let teams = entries.filter(\.isTeam)
        let leagues = entries.filter { !$0.isTeam }
        if !teams.isEmpty {
            result.append(.init(id: "teams", title: "Teams", rows: teams.map(row)))
        }
        if !leagues.isEmpty {
            result.append(.init(id: "leagues", title: "Leagues", rows: leagues.map(row)))
        }
        result.append(.init(id: "manage", isSeparated: true, rows: [
            .init(id: "manage", title: Text("Manage Teams"), systemImage: "person.2.badge.plus", action: onManageTeams)
        ]))
        return result
    }

    private func row(_ entry: Entry) -> BrowseSidebarPanel.Row {
        .init(id: "follow:\(entry.key)", title: Text(verbatim: entry.title), imageURL: entry.logoURL) {
            onSelect(entry.key)
        }
    }
}
