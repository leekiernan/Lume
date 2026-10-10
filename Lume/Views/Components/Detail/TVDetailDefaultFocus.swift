import SwiftUI

#if os(tvOS)
    extension View {
        /// A detail screen may be recreated while the viewer is still moving
        /// across the tab bar. Declare its landing *inside* its own scope; do
        /// not write FocusState on appearance or after asynchronous enrichment.
        /// Those writes try to pull focus off the tab bar during stack restore.
        func tvDetailDefaultFocus<Value: Hashable>(
            _ focus: FocusState<Value?>.Binding, _ target: Value
        ) -> some View {
            modifier(TVDetailDefaultFocus(focus: focus, target: target))
        }
    }

    private struct TVDetailDefaultFocus<Value: Hashable>: ViewModifier {
        let focus: FocusState<Value?>.Binding
        let target: Value
        @Namespace private var scope

        func body(content: Content) -> some View {
            content
                // Prefer the action on user-driven entry as well as initial
                // presentation. This declares a landing, never grabs focus
                // after enrichment or while the viewer moves across tabs.
                .defaultFocus(focus, target, priority: .userInitiated)
                .focusScope(scope)
                .focusSection()
        }
    }
#endif
