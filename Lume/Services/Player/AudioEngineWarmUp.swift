import AVFoundation
import Foundation

/// Pays Core Audio's first-use cost before anyone presses Play.
///
/// KSPlayer builds its audio output (`AVAudioEngine` with a time-pitch unit)
/// on the main thread as a stream opens. The first engine in a process also
/// loads and registers Core Audio's components — about 1.5 s on Apple TV, most
/// of the hang between Play and the player appearing. That registration is
/// once per process, so building and discarding one engine off the main
/// thread shortly after launch leaves KSPlayer's own engine cheap to create.
///
/// Nothing is started: no audio session is activated and no I/O runs, so
/// other apps' audio is untouched.
nonisolated enum AudioEngineWarmUp {
    /// After launch settles, so it doesn't compete with the first screen.
    static func schedule(after delay: TimeInterval = 3) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            _ = once
        }
    }

    /// Lazily initialised exactly once, thread-safely, by the first caller.
    private static let once: Void = Perf.measure(.audioWarmUp) {
        let engine = AVAudioEngine()
        let timePitch = AVAudioUnitTimePitch()
        engine.attach(timePitch)
        // The mixer drags in the output node, as KSPlayer's graph does.
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
    }
}
