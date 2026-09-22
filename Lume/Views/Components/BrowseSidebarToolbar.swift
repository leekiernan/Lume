//
//  BrowseSidebarToolbar.swift
//  Lume
//
//  The affordances that reveal `LibraryBrowseSidebar`. The sidebar is hidden by
//  default, so each platform needs somewhere to ask for it: a leading toolbar
//  button on iOS / macOS / visionOS, and — since the Movies and Series pages
//  carry no toolbar on tvOS (see `LibraryToolbar`) — a left press on a rail's
//  leading card reveals it (`onLeadingEdgeLeft`).
//

import SwiftUI

extension View {
    /// The toolbar entry point. A no-op on tvOS, which reveals the panel by
    /// focus instead of by a button.
    func browseSidebarToolbar(isPresented: Binding<Bool>, isEnabled: Bool) -> some View {
        modifier(BrowseSidebarToolbar(isPresented: isPresented, isEnabled: isEnabled))
    }

    /// tvOS: fires when the user presses left on this view. Attached to a rail's
    /// *leading* card only, so it means "left from the leftmost item" — a
    /// page-level handler fires on every left press, wherever focus sits, and
    /// would open the sidebar mid-row.
    @ViewBuilder
    func onLeadingEdgeLeft(_ action: (() -> Void)?) -> some View {
        #if os(tvOS)
            if let action {
                onMoveCommand { direction in
                    guard direction == .left else { return }
                    // Defer out of the move-command handler: tvOS delivers it
                    // inside the focus engine's animated update, and presenting
                    // from there animates the whole page at the UIKit layer (see
                    // `TVHomeScreen`'s hero paging for the same hop).
                    Task { action() }
                }
            } else {
                self
            }
        #else
            self
        #endif
    }
}

private struct BrowseSidebarToolbar: ViewModifier {
    @Binding var isPresented: Bool
    let isEnabled: Bool

    func body(content: Content) -> some View {
        #if os(tvOS)
            content
        #else
            content.toolbar {
                #if os(macOS)
                    ToolbarItem(placement: .navigation) { button.disabled(!isEnabled) }
                #else
                    ToolbarItem(placement: .topBarLeading) { button.disabled(!isEnabled) }
                #endif
            }
        #endif
    }

    #if !os(tvOS)
        private var button: some View {
            Button {
                isPresented.toggle()
            } label: {
                Label("Browse", systemImage: "line.3.horizontal")
            }
            .accessibilityLabel("Browse Categories")
        }
    #endif
}

/// A standing entry point to the browse sidebar, rendered below a page's rows.
/// Keeps the page from being actionless when every row happens to resolve to
/// nothing (a fresh catalog with no history, favorites or TMDB matches), and
/// makes the demoted categories discoverable besides.
struct BrowseCategoriesButton: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label("Browse All Categories", systemImage: "square.grid.2x2")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.top, 8)
    }
}
