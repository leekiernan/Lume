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
                entries: SportsHubGrouping(scope: scope, follows: follows.follows, store: .shared).sidebarEntries,
                onSelect: { key in
                    showingBrowse = false
                    open(follow: key)
                },
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
            guard leading, pageKey == nil else { return nil }
            return { openBrowse() }
        }

        func openBrowse() {
            browseReturnFocus = focus
            showingBrowse = true
        }

        /// Focus back where the panel was opened from.
        func returnFromBrowse() {
            guard let target = browseReturnFocus else { return }
            Task { @MainActor in focus = target }
        }
    }

#endif
