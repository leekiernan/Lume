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
    /// Home's brand shows once per launch, as the splash lifts.
    var hasShownBrand = false
    private let shownAt = Date()

    func send(_ event: LaunchCover.Event) {
        guard cover.handle(event), case let .revealed(reason) = cover.state else { return }
        let seconds = Date().timeIntervalSince(shownAt)
        Logger.home.info("launch splash lifted (\(reason.rawValue, privacy: .public)) after \(seconds, format: .fixed(precision: 1))s")
    }
}

/// The splash itself: the launch screen's mark, size and ground, so the
/// hand-over doesn't show. The rings glow outwards and the wordmark arrives
/// (the brand board's launch); if Home is still not ready after that, the mark
/// pulses as the wait indicator.
struct LaunchSplashView: View {
    @State private var isWaiting = false
    @State private var wordmarkArrived = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LumeAmbientBackground(style: .brand)
            VStack(spacing: LaunchSplashMetrics.gap) {
                LumeMark(motion: isWaiting ? .pulse : .launch)
                    .frame(width: LaunchSplashMetrics.mark, height: LaunchSplashMetrics.mark)
                LumeWordmark(size: LaunchSplashMetrics.wordmark, color: Color(white: 0.96))
                    // The board's line-height: 1, so the mark sits where the
                    // static launch image puts it.
                    .frame(height: LaunchSplashMetrics.wordmark)
                    .opacity(wordmarkArrived ? 1 : 0)
                    .offset(y: wordmarkArrived ? 0 : 14)
            }
        }
        .task {
            // The board's launch: the wordmark rises in at 1.92 s, over 0.84 s.
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.84).delay(1.92)) { wordmarkArrived = true }
            try? await Task.sleep(for: .seconds(LumeMarkFrame.launchDuration + 0.4))
            isWaiting = true
        }
    }
}

/// Matches `LaunchMark` (the static launch screen): a 300-point mark over the
/// wordmark's space, centred together.
enum LaunchSplashMetrics {
    static let mark: CGFloat = 300
    static let gap: CGFloat = 12
    static let wordmark: CGFloat = 88
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

/// Home's brand, top leading beside the tab bar: revealed as the splash lifts
/// over Home, and gone a few seconds later. Once per launch.
private struct LaunchBrandOverlay: ViewModifier {
    @Environment(LaunchSplashModel.self) private var splash: LaunchSplashModel?
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isVisible {
                    HStack(spacing: 8) {
                        LumeMark()
                            .frame(width: 60, height: 60)
                        LumeWordmark(size: 32, color: Color(white: 0.96))
                    }
                    .padding(.leading, 80)
                    .padding(.top, 50)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .task(id: splash?.cover.state) {
                guard let splash, !splash.hasShownBrand,
                      case let .revealed(reason) = splash.cover.state, reason != .homeNotShown else { return }
                splash.hasShownBrand = true
                // Already up as the splash fades off it; the board holds it
                // about 3.4 s, then fades it out.
                isVisible = true
                try? await Task.sleep(for: .seconds(3.4))
                withAnimation(.easeInOut(duration: 0.9)) { isVisible = false }
            }
    }
}

extension View {
    /// Home's brand, briefly, as the launch splash lifts.
    func launchBrand() -> some View {
        modifier(LaunchBrandOverlay())
    }

    /// Covers the app with the launch splash until Home has something to show.
    func launchSplash(homeShown: Bool) -> some View {
        modifier(LaunchSplashCover(homeShown: homeShown))
    }
}
