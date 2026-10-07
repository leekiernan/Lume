import SwiftUI

/// Opening uses the existing brand ground. Buffering leaves the last video
/// frame visible under a dimmer; video surfaces and letterboxing stay black.
struct PlayerLoadingBackground: View {
    let isOpening: Bool

    var body: some View {
        if isOpening {
            LumeAmbientBackground(style: .brand)
        } else {
            Color.black.opacity(0.4).ignoresSafeArea()
        }
    }
}
