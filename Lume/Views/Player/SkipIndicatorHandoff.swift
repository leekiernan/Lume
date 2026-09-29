//
//  SkipIndicatorHandoff.swift
//  Lume
//
//  The skip indicator and the loading spinner both sit centred over the
//  picture, and a skip is usually followed by a short buffer — so the spinner
//  used to replace the indicator before it could be read. While the indicator
//  is up it stands in for the spinner (with a small one of its own), and it
//  stays until the seek has finished loading.
//
//  The two live in different views: the indicator in the tvOS controls
//  overlay, the spinner in each engine view. They meet through the engine's
//  root, which every engine marks with `reportsPlayback(…)`: the overlay says
//  its indicator is showing (a preference, up), the root hands that and the
//  engine's buffering flag back down (the environment).
//

import SwiftUI

/// Whether the skip indicator is on screen — set by the overlay.
struct SkipIndicatorShowingKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension EnvironmentValues {
    /// The indicator is showing; the loading spinner steps aside for it.
    @Entry var skipIndicatorShowing = false
    /// The engine is buffering; the indicator stays up through it.
    @Entry var playerBuffering = false
}

private struct SkipIndicatorHandoff: ViewModifier {
    let buffering: Bool
    @State private var indicatorShowing = false

    func body(content: Content) -> some View {
        content
            .environment(\.playerBuffering, buffering)
            .environment(\.skipIndicatorShowing, indicatorShowing)
            .onPreferenceChange(SkipIndicatorShowingKey.self) { indicatorShowing = $0 }
    }
}

extension View {
    func skipIndicatorHandoff(buffering: Bool) -> some View {
        modifier(SkipIndicatorHandoff(buffering: buffering))
    }
}
