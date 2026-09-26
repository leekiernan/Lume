//
//  TVPlayPauseLongPress.swift
//  Lume
//
//  Resolves Play/Pause consistently: a short press switches profile, while a
//  long press opens the confirmed profile refresh flow.
//

#if os(tvOS)
    import SwiftUI
    import UIKit

    struct TVPlayPauseGesture: UIViewRepresentable {
        let onShortPress: @MainActor () -> Void
        let onLongPress: @MainActor () -> Void

        func makeUIView(context _: Context) -> ProbeView {
            let view = ProbeView()
            view.onShortPress = onShortPress
            view.onLongPress = onLongPress
            return view
        }

        func updateUIView(_ view: ProbeView, context _: Context) {
            view.onShortPress = onShortPress
            view.onLongPress = onLongPress
        }

        final class ProbeView: UIView {
            var onShortPress: (@MainActor () -> Void)?
            var onLongPress: (@MainActor () -> Void)?
            private weak var observedWindow: UIWindow?
            private lazy var shortPressRecognizer: UITapGestureRecognizer = {
                let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleShortPress))
                recognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
                recognizer.cancelsTouchesInView = false
                return recognizer
            }()

            private lazy var longPressRecognizer: UILongPressGestureRecognizer = {
                let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
                recognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
                recognizer.minimumPressDuration = 0.55
                recognizer.cancelsTouchesInView = false
                return recognizer
            }()

            override func didMoveToWindow() {
                super.didMoveToWindow()
                guard observedWindow !== window else { return }
                observedWindow?.removeGestureRecognizer(shortPressRecognizer)
                observedWindow?.removeGestureRecognizer(longPressRecognizer)
                observedWindow = window
                shortPressRecognizer.require(toFail: longPressRecognizer)
                window?.addGestureRecognizer(shortPressRecognizer)
                window?.addGestureRecognizer(longPressRecognizer)
            }

            deinit {
                observedWindow?.removeGestureRecognizer(shortPressRecognizer)
                observedWindow?.removeGestureRecognizer(longPressRecognizer)
            }

            @objc private func handleShortPress() {
                Task { @MainActor [onShortPress] in onShortPress?() }
            }

            @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
                guard recognizer.state == .began else { return }
                Task { @MainActor [onLongPress] in onLongPress?() }
            }
        }
    }
#endif
