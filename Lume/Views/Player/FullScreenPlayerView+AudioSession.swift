//
//  FullScreenPlayerView+AudioSession.swift
//  Lume
//
//  The player's global audio-session handling, split out of
//  `FullScreenPlayerView` to keep that file inside the 600-line cap.
//
//  Only LumeEngine needs this: KSPlayer and VLCKit configure `AVAudioSession`
//  themselves, so these two calls are no-ops from their point of view but must
//  still bracket every session, since the engine in use can change mid-player
//  through a fallback.
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
