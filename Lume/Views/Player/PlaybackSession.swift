//
//  PlaybackSession.swift
//  Lume
//
//  The full-screen player's live `PlaybackSessionMachine`: owned by the host,
//  handed to the engine view it builds, journalled on every transition. The
//  host installs `perform` to carry out effects (it holds what they need —
//  the scrobbler, the progress writer, the engine list).
//

import OSLog
import SwiftUI

@MainActor
@Observable
final class PlaybackSession {
    private(set) var machine = PlaybackSessionMachine()

    /// Carries out an effect. Installed by the host before the first event.
    @ObservationIgnored var perform: ((PlaybackSessionMachine.Effect) -> Void)?

    var state: PlaybackSessionMachine.State {
        machine.state
    }

    func send(_ event: PlaybackSessionMachine.Event) {
        let before = machine.state
        guard let effects = machine.handle(event) else { return }
        if machine.state != before {
            Logger.player.info("session: \(before.logName) → \(machine.state.logName)")
        }
        for effect in effects {
            perform?(effect)
        }
    }
}

extension View {
    /// Reports an engine's flags to the full-screen session, and raises the
    /// engine's own failure overlay when the session failed with no engine left
    /// to fall back to. A no-op without a session (Multi-View tiles).
    /// `failureOverlay` is the engine's own overlay flag — the one the report's
    /// `failed` reads.
    func reportsPlayback(
        to session: PlaybackSession?,
        engine: PlayerEngineKind,
        report: PlaybackSessionMachine.EngineReport,
        failureOverlay: Binding<Bool>
    ) -> some View {
        onChange(of: report, initial: true) { _, report in
            session?.send(.reported(engine, report))
        }
        .onChange(of: session?.machine.showsFailure == true) { _, shows in
            if shows, !failureOverlay.wrappedValue {
                failureOverlay.wrappedValue = true
            }
        }
        .skipIndicatorHandoff(buffering: report.buffering)
    }
}
