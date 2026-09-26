//
//  TVPlayPauseLongPress.swift
//  Lume
//
//  Observes a long Play/Pause press without replacing SwiftUI's short-press
//  command. The root uses the latter for quick profile switching; a long press
//  opens the confirmed profile refresh flow instead.
//

#if os(tvOS)
    import SwiftUI
    import UIKit

    struct TVPlayPauseLongPress: UIViewRepresentable {
        let action: @MainActor () -> Void

        func makeUIView(context _: Context) -> ProbeView {
            let view = ProbeView()
            view.action = action
            return view
        }

        func updateUIView(_ view: ProbeView, context _: Context) {
            view.action = action
        }

        final class ProbeView: UIView {
            var action: (@MainActor () -> Void)?
            private weak var observedWindow: UIWindow?
            private lazy var recognizer: UILongPressGestureRecognizer = {
                let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
                recognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
                recognizer.minimumPressDuration = 0.55
                recognizer.cancelsTouchesInView = false
                return recognizer
            }()

            override func didMoveToWindow() {
                super.didMoveToWindow()
                guard observedWindow !== window else { return }
                observedWindow?.removeGestureRecognizer(recognizer)
                observedWindow = window
                window?.addGestureRecognizer(recognizer)
            }

            deinit {
                observedWindow?.removeGestureRecognizer(recognizer)
            }

            @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
                guard recognizer.state == .began else { return }
                Task { @MainActor [action] in action?() }
            }
        }
    }
#endif
