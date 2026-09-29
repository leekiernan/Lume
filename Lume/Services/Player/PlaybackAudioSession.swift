import AVFoundation
import Foundation
import OSLog

/// Serialises ownership of the process-wide audio session.
///
/// A full-screen player can dismiss while the next player is already mounting.
/// Calling `setActive(false)` directly from the disappearing view then races the
/// successor's activation. The actor makes the ordering explicit and performs
/// the potentially-blocking AudioSession calls away from SwiftUI's main actor.
actor PlaybackAudioSession {
    nonisolated static let shared = PlaybackAudioSession()

    enum Configuration: Equatable {
        case fullScreen
        case multiView
    }

    private var lease = PlaybackAudioSessionLease()

    func activate(owner: UUID, configuration: Configuration) {
        guard lease.claim(owner) else { return }

        #if os(iOS) || os(tvOS)
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback, options: [])
            if configuration == .fullScreen {
                let maxChannels = session.maximumOutputNumberOfChannels
                if maxChannels > 2 {
                    try? session.setPreferredOutputNumberOfChannels(maxChannels)
                }
            }
            try? session.setActive(true, options: [])

            if configuration == .fullScreen {
                let route = session.currentRoute.outputs
                    .map { "\($0.portType.rawValue)(\($0.channels?.count ?? 0)ch)" }
                    .joined(separator: "+")
                Logger.player.info("""
                Audio session active: route=\(route, privacy: .public) \
                outputChannels=\(session.outputNumberOfChannels) \
                maxChannels=\(session.maximumOutputNumberOfChannels) sampleRate=\(session.sampleRate)
                """)
            }
        #endif
    }

    func deactivate(owner: UUID) {
        guard lease.release(owner) else { return }
        #if os(iOS) || os(tvOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

/// Small, pure ownership state machine kept separate from the platform call so
/// stale teardown is testable without touching the global `AVAudioSession`.
struct PlaybackAudioSessionLease {
    private(set) var activeOwner: UUID?

    /// Returns whether the caller acquired a new lease and must configure the
    /// platform session. Repeating activation by its existing owner is a no-op.
    mutating func claim(_ owner: UUID) -> Bool {
        guard activeOwner != owner else { return false }
        activeOwner = owner
        return true
    }

    /// Returns whether this caller still owned the session and therefore may
    /// deactivate it. A dismissed predecessor cannot tear down its successor.
    mutating func release(_ owner: UUID) -> Bool {
        guard activeOwner == owner else { return false }
        activeOwner = nil
        return true
    }
}
