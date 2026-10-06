import Foundation
@testable import Lume
import Testing

struct PlayerScrubMachineTests {
    @Test func `select commits the preview and consumes the session once`() {
        var scrub = PlayerScrubMachine()
        #expect(scrub.begin(current: 120, isPlaying: true) == true)
        #expect(scrub.isScrubbing)
        scrub.move(to: 180)
        #expect(scrub.target == 180)
        #expect(scrub.finish(duration: 600, commit: true) == .init(seekTarget: 180, resume: true))
        #expect(!scrub.isScrubbing)
        #expect(scrub.finish(duration: 600, commit: true) == nil)
        // A seek's synchronous playback callback cannot re-enter the preview.
        #expect(scrub.playbackChanged(isPlaying: true) == false)
    }

    @Test func `play pause commits and plays even when scrubbing began paused`() {
        var scrub = PlayerScrubMachine()
        #expect(scrub.begin(current: 120, isPlaying: false) == false)
        scrub.move(to: 150)
        #expect(scrub.finish(duration: 600, commit: true, play: true) == .init(seekTarget: 150, resume: true))
        #expect(!scrub.isScrubbing)
    }

    @Test(arguments: [true, false])
    func `back abandons the preview and restores the entry play state`(playing: Bool) {
        var scrub = PlayerScrubMachine()
        #expect(scrub.begin(current: 120, isPlaying: playing) == playing)
        scrub.move(to: 180)
        #expect(scrub.finish(duration: 600, commit: false) == .init(seekTarget: nil, resume: playing))
        #expect(!scrub.isScrubbing)
    }

    @Test func `select from a paused picture does not request playback`() {
        var scrub = PlayerScrubMachine()
        _ = scrub.begin(current: 120, isPlaying: false)
        #expect(scrub.finish(duration: 600, commit: true) == .init(seekTarget: 120, resume: false))
    }

    @Test func `external playback resumption releases frozen labels and the panel hold`() {
        var scrub = PlayerScrubMachine()
        _ = scrub.begin(current: 120, isPlaying: true)
        var panelOpen = true
        #expect(scrub.playbackChanged(isPlaying: false) == false)
        scrub.move(to: 180)
        if scrub.playbackChanged(isPlaying: true) { panelOpen = false }
        #expect(!scrub.isScrubbing)
        #expect(!panelOpen)
        // No extra seek/play is issued after the engine already resumed.
        #expect(scrub.finish(duration: 600, commit: true) == nil)
        #expect(scrub.playbackChanged(isPlaying: true) == false)
    }

    @Test func `playing before the pause acknowledgement does not end the scrub`() {
        var scrub = PlayerScrubMachine()
        _ = scrub.begin(current: 120, isPlaying: true)
        #expect(scrub.playbackChanged(isPlaying: true) == false)
        #expect(scrub.isScrubbing)
        #expect(scrub.playbackChanged(isPlaying: false) == false)
        #expect(scrub.playbackChanged(isPlaying: true) == true)
        #expect(!scrub.isScrubbing)
    }

    @Test func `resuming an initially paused scrub releases it without waiting for another pause`() {
        var scrub = PlayerScrubMachine()
        _ = scrub.begin(current: 120, isPlaying: false)
        #expect(scrub.playbackChanged(isPlaying: true) == true)
        #expect(!scrub.isScrubbing)
    }

    @Test func `repeated begin cannot overwrite the target or original play state`() {
        var scrub = PlayerScrubMachine()
        _ = scrub.begin(current: 120, isPlaying: true)
        scrub.move(to: 180)
        #expect(scrub.begin(current: 300, isPlaying: false) == false)
        #expect(scrub.finish(duration: 600, commit: true) == .init(seekTarget: 180, resume: true))
    }

    @Test func `reset removes a stale preview before the next interaction`() {
        var scrub = PlayerScrubMachine()
        _ = scrub.begin(current: 120, isPlaying: true)
        scrub.move(to: 180)
        scrub.reset()
        #expect(!scrub.isScrubbing)
        #expect(scrub.finish(duration: 600, commit: false) == nil)
        #expect(scrub.playbackChanged(isPlaying: true) == false)
        #expect(scrub.begin(current: 300, isPlaying: false) == false)
        #expect(scrub.target == 300)
    }

    @Test func `targets are finite and committed within the timeline`() {
        var scrub = PlayerScrubMachine()
        _ = scrub.begin(current: .nan, isPlaying: false)
        #expect(scrub.target == 0)
        scrub.move(to: .infinity)
        #expect(scrub.target == 0)
        scrub.move(to: 700)
        #expect(scrub.finish(duration: 600, commit: true)?.seekTarget == 600)
        _ = scrub.begin(current: -10, isPlaying: false)
        #expect(scrub.target == 0)
        #expect(scrub.finish(duration: .infinity, commit: true)?.seekTarget == 0)
    }
}
