import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

    // MARK: - Video Container (platform view bridge)

// Hosts the plain platform view that VLC renders into. The coordinator is
// set as the player's `drawable`; VLC calls back into it to insert its
// output surface and to query bounds.
// Shared by full-screen playback and Multi-View. The caller owns the coordinator
// and playback lifecycle; embedded mode must be set before this view mounts.
#if os(macOS)
    struct VLCVideoContainer: NSViewRepresentable {
        let coordinator: VLCPlayerCoordinator

        func makeNSView(context _: Context) -> NSView {
            // Deliberately NOT layer-backed: VLCKit's macOS video output
            // inserts a legacy `NSOpenGLView`. Inside a layer-backed view
            // tree, on Apple Silicon's deprecated OpenGL-on-Metal shim,
            // VLC's renderer aborts with `GL_INVALID_OPERATION` in
            // `CreateFilters` (vout_helper.c). Leaving `wantsLayer` unset
            // lets the GL view present the traditional, non-layer-backed
            // way. SwiftUI may still force layer-backing from an ancestor;
            // if so this won't be enough and macOS playback should fall
            // back to a Metal-based engine (KSPlayer).
            let view = NSView()
            coordinator.attach(hostView: view)
            return view
        }

        func updateNSView(_: NSView, context _: Context) {}
    }
#else
    struct VLCVideoContainer: UIViewRepresentable {
        let coordinator: VLCPlayerCoordinator

        func makeUIView(context _: Context) -> UIView {
            let view = UIView()
            view.backgroundColor = .black
            coordinator.attach(hostView: view)
            return view
        }

        func updateUIView(_: UIView, context _: Context) {}
    }
#endif
