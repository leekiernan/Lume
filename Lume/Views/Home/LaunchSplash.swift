//
//  LaunchSplash.swift
//  Lume
//
//  The launch screen's logo, carried on over the app until Home has something
//  to show — see `LaunchCover`. tvOS only: elsewhere Home draws placeholders
//  while it loads.
//

import OSLog
import SwiftUI

@MainActor
@Observable
final class LaunchSplashModel {
    private(set) var cover = LaunchCover()
    private let shownAt = Date()

    func send(_ event: LaunchCover.Event) {
        guard cover.handle(event), case let .revealed(reason) = cover.state else { return }
        let seconds = Date().timeIntervalSince(shownAt)
        Logger.home.info("launch splash lifted (\(reason.rawValue, privacy: .public)) after \(seconds, format: .fixed(precision: 1))s")
    }
}

/// The splash itself: the same logo, size and background as the launch
/// screen, so the hand-over doesn't show, with a spinner if it's a wait.
struct LaunchSplashView: View {
    @State private var showsProgress = false

    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            Image("LaunchLogo")
                .overlay(alignment: .bottom) {
                    ProgressView()
                        .opacity(showsProgress ? 1 : 0)
                        .offset(y: 120)
                }
        }
        .task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { showsProgress = true }
        }
    }
}

private struct LaunchSplashCover: ViewModifier {
    let homeShown: Bool
    @State private var model = LaunchSplashModel()

    func body(content: Content) -> some View {
        content
            .environment(model)
            .overlay {
                if model.cover.isCovering {
                    LaunchSplashView()
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.35), value: model.cover.isCovering)
            .task {
                try? await Task.sleep(for: LaunchCover.longest)
                model.send(.timedOut)
            }
            .onChange(of: homeShown, initial: true) { _, shown in
                if !shown { model.send(.otherTabShown) }
            }
    }
}

extension View {
    /// Covers the app with the launch splash until Home has something to show.
    func launchSplash(homeShown: Bool) -> some View {
        modifier(LaunchSplashCover(homeShown: homeShown))
    }
}
