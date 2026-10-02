//
//  TVSportsHubScreen+Browse.swift
//  Lume
//
//  The hub's scope panel: `SportsBrowseSidebar` over the page, opened by a
//  left press from the page's leading edge or by selecting the title, with
//  focus handed back to where it was when the panel closes.
//

#if os(tvOS)

    import SwiftUI

    extension TVSportsHubScreen {
        var browseSidebar: some View {
            SportsBrowseSidebar(
                isPresented: $showingBrowse,
                leagues: SportsHubGrouping.followedLeagues(follows.follows),
                scope: scope,
                onSelect: selectScope,
                onManageTeams: {
                    showingBrowse = false
                    showManageTeams = true
                },
                onReturnToContent: returnFromBrowse
            )
        }

        /// The rail's first card opens the panel on a left press; the rest
        /// just move left.
        func browseOpener(leading: Bool) -> (() -> Void)? {
            guard leading else { return nil }
            return { openBrowse() }
        }

        func openBrowse() {
            browseReturnFocus = focus
            showingBrowse = true
        }

        func selectScope(_ value: SportsHubScope) {
            scope = value
            showingBrowse = false
            // A new scope is a new page: land on the title, at the top.
            browseReturnFocus = .scope
            returnFromBrowse()
        }

        /// Focus back where the panel was opened from.
        func returnFromBrowse() {
            let target = browseReturnFocus ?? .scope
            Task { @MainActor in focus = target }
        }
    }

#endif
