//
//  BrowseSidebarFocus.swift
//  Lume
//
//  tvOS focus behaviour shared by the two browse panels — `LibraryBrowseSidebar`
//  (Movies, Series) and `LiveTVBrowseSidebar`. A panel that slides in over the
//  page has to *take* focus, or the page underneath stays live: the user keeps
//  navigating a list they can no longer read, and neither Menu nor a press to
//  the right reaches the panel, so there is no way back out of it.
//
//  Landing follows `landTVFocus`, the same release-settle-assert every tvOS
//  surface over live content uses — scrolling to the target first, because the
//  row to land on is routinely below the fold in a long category list.
//
//  Where to land is the caller's `target`, and the panel remembers the row it
//  was last left on so reopening returns there rather than to the top. That
//  matters wherever a panel is opened repeatedly against a live selection.
//
//  tvOS only — every other platform has a pointer and a close button.
//

#if os(tvOS)

    import SwiftUI

    extension View {
        /// Moves focus into a browse panel when it opens, and closes it when
        /// focus leaves. Apply to the panel's scrolling content, inside the
        /// `ScrollViewReader` whose `proxy` this is given.
        ///
        /// `lastFocused` records the row focus was last on; keep it on the
        /// sidebar itself, which outlives the panel, and fold it into `target`.
        func browseSidebarFocus<Item: Hashable>(
            isPresented: Binding<Bool>,
            focus: FocusState<Item?>.Binding,
            scrollProxy: ScrollViewProxy,
            lastFocused: Binding<Item?>,
            onReturnToContent: (() -> Void)? = nil,
            target: @escaping () -> Item?
        ) -> some View {
            modifier(BrowseSidebarFocus(
                isPresented: isPresented,
                focus: focus,
                scrollProxy: scrollProxy,
                lastFocused: lastFocused,
                onReturnToContent: onReturnToContent,
                target: target
            ))
        }
    }

    private struct BrowseSidebarFocus<Item: Hashable>: ViewModifier {
        @Binding var isPresented: Bool
        let focus: FocusState<Item?>.Binding
        let scrollProxy: ScrollViewProxy
        @Binding var lastFocused: Item?
        /// Puts focus back where the page had it, for the panel to call as it
        /// closes. Without one, the page is left to the focus engine.
        let onReturnToContent: (() -> Void)?
        let target: () -> Item?

        /// Focus arrives a beat after the panel appears; until it has, a nil
        /// focus value means "not there yet", not "focus left". Fresh on every
        /// open, since the panel is built anew each time.
        @State private var didTakeFocus = false

        func body(content: Content) -> some View {
            content
                // Menu closes the panel rather than leaving the tab.
                .onExitCommand { if isPresented { returnToContent() } }
                .onMoveCommand { direction in
                    // Right is the way out, so take it rather than let the
                    // engine move focus into the page first: it would land
                    // beside whichever panel row was focused, and putting that
                    // right afterwards is the highlight jumping again. Nothing
                    // in the panel sits to the right of anything else, so
                    // claiming this direction swallows no in-panel move.
                    guard direction == .right, isPresented else { return }
                    Task { returnToContent() }
                }
                .task {
                    await landTVFocus(focus, on: target(), scrollingTo: scrollProxy) { isPresented }
                }
                .onChange(of: focus.wrappedValue) { _, item in
                    guard isPresented else { return }
                    if let item {
                        didTakeFocus = true
                        // Where to reopen: wherever the panel was left.
                        lastFocused = item
                        return
                    }
                    // Focus left the panel some other way than the exits
                    // above. Confirm a hop later: focus briefly reads nil while
                    // it moves between rows inside the panel too.
                    guard didTakeFocus else { return }
                    Task {
                        guard focus.wrappedValue == nil, isPresented else { return }
                        returnToContent()
                    }
                }
        }

        /// Closes the panel and hands focus back to the page in one move.
        private func returnToContent() {
            isPresented = false
            onReturnToContent?()
        }
    }

#endif
