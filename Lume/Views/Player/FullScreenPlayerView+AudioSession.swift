//
//  FullScreenPlayerView+AudioSession.swift
//  Lume
//
//  The player's global audio-session handling, split out of
//  `FullScreenPlayerView` to keep that file inside the 600-line cap.
//
//  The shared audio-session lease brackets full-screen playback and survives
//  engine fallback, even when an engine also configures its own session.
//

extension FullScreenPlayerView {
    /// The shared owner actor both keeps the potentially-blocking platform call
    /// off the main actor and prevents an old player from racing a successor's
    /// activation during a quick stream switch.
    func configureAudioSessionForPlayback() async {
        await PlaybackAudioSession.shared.activate(owner: audioSessionOwner, configuration: .fullScreen)
    }

    /// The actor serialises this after every activation. If a successor acquired
    /// the lease first, this becomes a safe no-op rather than deactivating it.
    func releaseAudioSession() {
        let owner = audioSessionOwner
        Task { await PlaybackAudioSession.shared.deactivate(owner: owner) }
    }
}
