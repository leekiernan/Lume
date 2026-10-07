import SwiftUI

#if os(tvOS)
    extension View {
        /// Page only past the outermost action, preserving focus movement
        /// between hero actions. Mutation leaves the focus animation context.
        @ViewBuilder
        func onCarouselEdge(_ edge: MoveCommandDirection, _ onPage: ((Int) -> Void)?) -> some View {
            if let onPage {
                onMoveCommand { direction in
                    guard direction == edge else { return }
                    Task { onPage(edge == .left ? -1 : 1) }
                }
            } else {
                self
            }
        }
    }
#endif
