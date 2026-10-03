//
//  PlayerSportsAlertsLayer.swift
//  Lume
//
//  The player's sports layer (tvOS): the alert toast top-right, and while the
//  player is on a detour from a film to a live game, the way back top-left.
//  A Play press while a toast shows switches to the game; Back with nothing
//  else to close returns to the film where it was left. Both presses reach
//  here through `PlayerControlsBridge`, since each engine owns the remote.
//

import SwiftData
import SwiftUI

extension View {
    /// Layers the sports alerts over the player. `position` reads the playback
    /// clock when a detour begins; `switchMedia` is the player's one swap path.
    func playerSportsAlerts(
        activeMedia: PlayableMedia,
        bridge: PlayerControlsBridge,
        position: @escaping () -> TimeInterval,
        switchMedia: @escaping (PlayableMedia) -> Void
    ) -> some View {
        #if os(tvOS)
            modifier(PlayerSportsAlertsLayer(
                activeMedia: activeMedia,
                bridge: bridge,
                position: position,
                switchMedia: switchMedia
            ))
        #else
            self
        #endif
    }
}

#if os(tvOS)

    /// The detour state the remote claim reads synchronously.
    @MainActor
    @Observable
    private final class PlayerDetourState {
        var machine = PlayerDetourMachine()
        private(set) var returnRequests = 0
        @ObservationIgnored private(set) var pendingReturn: PlayableMedia?

        /// Back with nothing else to close: take it when there's a way back.
        func claimBack() -> Bool {
            guard machine.origin != nil else { return false }
            for effect in machine.handle(.backPressed) {
                if case let .returnTo(media) = effect { pendingReturn = media }
            }
            returnRequests += 1
            return true
        }

        func takeReturn() -> PlayableMedia? {
            defer { pendingReturn = nil }
            return pendingReturn
        }
    }

    private struct PlayerSportsAlertsLayer: ViewModifier {
        let activeMedia: PlayableMedia
        let bridge: PlayerControlsBridge
        let position: () -> TimeInterval
        let switchMedia: (PlayableMedia) -> Void

        @Environment(\.modelContext) private var modelContext
        @Environment(\.contentRestriction) private var restriction
        @State private var alerts = SportsAlertCoordinator.shared
        @State private var detour = PlayerDetourState()

        func body(content: Content) -> some View {
            content
                .overlay(alignment: .topTrailing) {
                    if let presented = alerts.presented {
                        SportsAlertToast(presentation: presented)
                            .padding(.top, 60)
                            .padding(.trailing, 80)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let origin = detour.machine.origin, detour.machine.pillVisible(controlsVisible: bridge.controlsVisible) {
                        PlayerDetourPill(origin: origin)
                            .padding(.top, 60)
                            .padding(.leading, 80)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.3), value: alerts.presented)
                .animation(.easeOut(duration: 0.3), value: detour.machine)
                .onAppear {
                    alerts.playbackBegan(media: activeMedia, container: modelContext.container, restriction: restriction)
                    bridge.playPauseClaim = { [alerts] in alerts.claimPlayPress() }
                    bridge.backClaim = { [detour] in detour.claimBack() }
                }
                .onDisappear {
                    alerts.playbackEnded()
                    bridge.playPauseClaim = nil
                    bridge.backClaim = nil
                }
                .onChange(of: activeMedia) { _, media in
                    alerts.mediaChanged(media)
                    // Back at the film by any route (the controls, a menu):
                    // the way back is spent.
                    if media.id == detour.machine.origin?.media.id {
                        detour.machine.handle(.ended)
                    }
                }
                .onChange(of: alerts.watchRequests) { _, _ in watchRequestedGame() }
                .onChange(of: detour.returnRequests) { _, _ in
                    if let media = detour.takeReturn() { switchMedia(media) }
                }
                .task(id: detour.machine.origin?.media.id) {
                    guard detour.machine.origin != nil else { return }
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled else { return }
                    detour.machine.handle(.arrivalElapsed)
                }
        }

        /// Switches to the alert's game. Leaving a film or episode starts a
        /// detour so Back returns to it; leaving a live channel doesn't need
        /// one — the player's channel recall already knows the way back.
        private func watchRequestedGame() {
            guard let channel = alerts.watchTarget?.channel,
                  let media = SportsPlayback.media(for: channel, in: modelContext)
            else { return }
            if activeMedia.kind == .vod, activeMedia.catchup == nil {
                detour.machine.handle(.began(.init(media: activeMedia, position: position())))
            }
            switchMedia(media)
        }
    }

    /// The top-right toast: what happened, and where Play takes you.
    private struct SportsAlertToast: View {
        let presentation: SportsAlertPresentation

        private var fixture: SportsFixture {
            presentation.alert.fixture
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(badge)
                        .font(.system(size: 18, weight: .heavy))
                        .tracking(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 8).fill(badgeFill))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(verbatim: contextLine)
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                HStack(spacing: 18) {
                    if let home = fixture.home { TeamCrest(team: home.team, size: 56) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: headline)
                            .font(.system(size: 32, weight: .bold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(verbatim: fixture.eventShortTitleOrMatchup)
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let away = fixture.away { TeamCrest(team: away.team, size: 56) }
                }
                if let channel = presentation.channel {
                    HStack(spacing: 12) {
                        Image(systemName: "playpause.fill")
                            .font(.system(size: 18, weight: .bold))
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(.white))
                            .foregroundStyle(.black)
                        Text("Watch on \(channel.stream.name)")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(width: 640, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .combine)
        }

        private var badge: LocalizedStringKey {
            if presentation.hidesScores { return "UPDATE" }
            switch presentation.alert.kind {
            case .score: return fixture.sport == "soccer" ? "GOAL" : "SCORE"
            case .kickoff: return "KICK-OFF"
            case .halfTime: return "HALF-TIME"
            case .finalResult: return "FULL TIME"
            }
        }

        private var badgeFill: Color {
            if presentation.hidesScores { return .white.opacity(0.18) }
            if presentation.alert.kind == .score,
               let scorer = presentation.alert.scoringTeamId,
               let team = fixture.team(forTeamId: scorer.split(separator: ":").last.map(String.init))
            {
                return TeamPalette(primaryHex: team.colorHex).primary
            }
            return .white.opacity(0.18)
        }

        /// "Arsenal 1–0 Chelsea", or under Hide Scores no score at all.
        private var headline: String {
            if presentation.hidesScores { return String(localized: "Something happened") }
            guard let home = fixture.home, let away = fixture.away else { return fixture.eventShortTitle }
            return "\(home.team.shortName) \(home.displayScore)–\(away.displayScore) \(away.team.shortName)"
        }

        private var contextLine: String {
            [fixture.leagueName, presentation.hidesScores ? nil : fixture.status.liveDetail(family: fixture.periodFamily, hidingScores: false)]
                .compactMap(\.self)
                .joined(separator: " · ")
        }
    }

    /// The way back from a detour.
    private struct PlayerDetourPill: View {
        let origin: PlayerDetourMachine.Origin

        var body: some View {
            HStack(spacing: 16) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 22, weight: .bold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Back to \(origin.media.title)")
                        .font(.system(size: 22, weight: .bold))
                        .lineLimit(1)
                    Text("Paused at \(Duration.seconds(origin.position).formatted(.time(pattern: .hourMinuteSecond))) · press Back")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(.regularMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

#endif
