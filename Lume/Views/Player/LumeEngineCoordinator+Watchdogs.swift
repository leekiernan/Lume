//
//  LumeEngineCoordinator+Watchdogs.swift
//  Lume
//
//  What a load waits for before it gives up: a first frame for a new stream,
//  playback resuming for a reconnect. Split from LumeEngineCoordinator.swift
//  to keep it within the length limit.
//

import Foundation
import LumeEngine
import LumeEngineCore
import OSLog

extension LumeEngineCoordinator {
    /// A reconnect's watchdog: the stream has already started, so there's no
    /// first frame to wait for — only playback resuming. If it doesn't within
    /// `startupTimeout`, the reload counts as another stall, which the view's
    /// reconnect budget either retries or gives up on.
    func makeReconnectWatchdog() -> Task<Void, Never> {
        Task { [startupTimeout] in
            try? await Task.sleep(for: .seconds(startupTimeout))
            guard !Task.isCancelled, !self.isPlaying else { return }
            Logger.player.error("LumeEngine reconnect didn't resume within \(startupTimeout, format: .fixed(precision: 0))s")
            self.onStalled?()
        }
    }

    /// Startup failure watchdog. The window is rolling while the engine
    /// demonstrably downloads: a multi-second buffer target on a ~1× link
    /// legitimately pre-buffers past any fixed window, while a dead stream
    /// shows no byte progress and still fails within `startupTimeout`. A hard
    /// cap bounds pathological "downloads but never starts" cases.
    func makeStartupWatchdog() -> Task<Void, Never> {
        Task { [startupTimeout] in
            let hardDeadline = Date(timeIntervalSinceNow: max(startupTimeout * 3, 60))
            var deadline = Date(timeIntervalSinceNow: startupTimeout)
            var lastBytes: Int64 = 0
            while !Task.isCancelled, !self.hasStartedPlayback {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, !self.hasStartedPlayback else { return }
                if let session = self.session {
                    let bytes = await session.diagnostics.deliveredBytes
                    if bytes > lastBytes {
                        lastBytes = bytes
                        deadline = min(Date(timeIntervalSinceNow: startupTimeout), hardDeadline)
                    }
                }
                if Date() >= deadline {
                    Logger.player.error("LumeEngine startup window elapsed (read \(lastBytes) bytes, never played)")
                    self.reportFailure()
                    return
                }
            }
        }
    }
}
