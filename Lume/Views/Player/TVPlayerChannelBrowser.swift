#if os(tvOS)
    import SwiftUI

    /// Presentation glue only. Each engine owns its stream selection and focus.
    struct TVPlayerChannelBrowser: View {
        let media: PlayableMedia
        @Binding var isPresented: Bool
        let chrome: PlayerChromeController
        let mayHide: () -> Bool
        let onSelect: (PlayableMedia) -> Void
        let onClose: () -> Void

        var body: some View {
            TVChannelBrowserOverlay(
                media: media,
                onSelect: { target in
                    onSelect(target)
                    withAnimation(.easeInOut(duration: 0.25)) { isPresented = false }
                    chrome.show(mayHide: mayHide)
                },
                onClose: onClose
            )
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }
#endif
