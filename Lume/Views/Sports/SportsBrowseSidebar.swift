//
//  SportsBrowseSidebar.swift
//  Lume
//
//  The Sports hub's scope — My Teams or one followed league — picked from the
//  shared `BrowseSidebarPanel` Movies, Series and Live TV use, with Manage
//  Teams at its foot. On tvOS it slides in on a left press from the page's
//  leading edge; elsewhere the toolbar's browse button or the title opens it.
//

import SwiftUI

struct SportsBrowseSidebar: View {
    @Binding var isPresented: Bool
    let leagues: [SportsLeague]
    let scope: SportsHubScope
    let onSelect: (SportsHubScope) -> Void
    let onManageTeams: () -> Void
    /// Hands focus back to where the page had it.
    var onReturnToContent: (() -> Void)?

    private static let myTeamsRow = "myTeams"

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
        case .myTeams: Self.myTeamsRow
        case let .league(id): "league:\(id)"
        }
    }

    private var sections: [BrowseSidebarPanel.Section] {
        var result = [BrowseSidebarPanel.Section(id: "mine", rows: [
            .init(id: Self.myTeamsRow, title: Text("My Teams"), systemImage: "star.fill") { onSelect(.myTeams) }
        ])]
        if !leagues.isEmpty {
            result.append(.init(id: "leagues", title: "Leagues", rows: leagues.map { league in
                .init(id: "league:\(league.id)", title: Text(verbatim: league.name), imageURL: league.logoURL) {
                    onSelect(.league(league.id))
                }
            }))
        }
        result.append(.init(id: "manage", isSeparated: true, rows: [
            .init(id: "manage", title: Text("Manage Teams"), systemImage: "person.2.badge.plus", action: onManageTeams)
        ]))
        return result
    }
}
