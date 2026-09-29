//
//  PlaybackSessionMachineTests.swift
//  LumeTests
//
//  The full-screen playback session: what each engine report means, and what
//  follows from it (Trakt, progress, engine fallback).
//

@testable import Lume
import Testing

@MainActor
struct PlaybackSessionMachineTests {
    private typealias Machine = PlaybackSessionMachine

    private func report(
        started: Bool = true, buffering: Bool = false, playing: Bool = true, failed: Bool = false
    ) -> Machine.EngineReport {
        Machine.EngineReport(started: started, buffering: buffering, playing: playing, failed: failed)
    }

    /// A session on KSPlayer that has reached `playing`.
    private func playingOnKS() -> Machine {
        var machine = Machine()
        _ = machine.handle(.starting(.ksPlayer, .open))
        _ = machine.handle(.reported(.ksPlayer, report()))
        return machine
    }

    @Test func `the first frame starts the scrobble`() {
        var machine = Machine()
        _ = machine.handle(.starting(.ksPlayer, .open))
        #expect(machine.handle(.reported(.ksPlayer, report(started: false, buffering: true, playing: false))) == [])
        #expect(machine.state == .starting(.open))
        #expect(machine.handle(.reported(.ksPlayer, report())) == [.scrobble(.start)])
        #expect(machine.state == .playing)
    }

    /// The reason the machine exists: a stall is not a pause.
    @Test func `a stall is rebuffering, not a pause`() {
        var machine = playingOnKS()
        #expect(machine.handle(.reported(.ksPlayer, report(buffering: true, playing: false))) == [])
        #expect(machine.state == .rebuffering)
        // Recovering restarts nothing Trakt hasn't already heard; the
        // scrobbler de-duplicates the repeated start.
        #expect(machine.handle(.reported(.ksPlayer, report())) == [.scrobble(.start)])
    }

    @Test func `a pause scrobbles a pause and saves progress`() {
        var machine = playingOnKS()
        #expect(machine.handle(.reported(.ksPlayer, report(playing: false))) == [.scrobble(.pause), .persistProgress])
        #expect(machine.state == .paused)
        #expect(machine.handle(.reported(.ksPlayer, report())) == [.scrobble(.start)])
    }

    @Test func `an engine that can't start falls back while another is left`() {
        var machine = Machine()
        _ = machine.handle(.starting(.ksPlayer, .open))
        #expect(machine.handle(.failedToStart(.ksPlayer, canFallBack: true)) == [.fallBackToNextEngine])
        #expect(machine.state == .starting(.fallback))
        _ = machine.handle(.starting(.vlcKit, .fallback))
        #expect(machine.engine == .vlcKit)
    }

    /// The fallback is decided when the engine fails: an AirPlay route that
    /// arrived since it was built leaves nothing to fall back to, and the
    /// session fails rather than leaving a spinner with no timeout.
    @Test func `with nothing left to try the session fails and asks for the overlay`() {
        var machine = Machine()
        _ = machine.handle(.starting(.avPlayer, .open))
        #expect(machine.handle(.failedToStart(.avPlayer, canFallBack: false)) == [])
        #expect(machine.state == .failed(.startup))
        #expect(machine.showsFailure)
    }

    @Test func `reports from an engine the session moved on from are ignored`() {
        var machine = Machine()
        _ = machine.handle(.starting(.ksPlayer, .open))
        _ = machine.handle(.failedToStart(.ksPlayer, canFallBack: true))
        _ = machine.handle(.starting(.vlcKit, .fallback))
        // The torn-down KSPlayer view's last report.
        #expect(machine.handle(.reported(.ksPlayer, report())) == nil)
        #expect(machine.state == .starting(.fallback))
    }

    @Test func `a start failure only counts while starting`() {
        var machine = playingOnKS()
        #expect(machine.handle(.failedToStart(.ksPlayer, canFallBack: true)) == nil)
        #expect(machine.state == .playing)
    }

    @Test func `giving up mid-stream stops the scrobble`() {
        var machine = playingOnKS()
        #expect(machine.handle(.reported(.ksPlayer, report(playing: false, failed: true))) == [.scrobble(.stop)])
        #expect(machine.state == .failed(.playback))
        // Try Again: the engine rejoins.
        _ = machine.handle(.reported(.ksPlayer, report(started: false, buffering: true, playing: false)))
        #expect(machine.state == .starting(.retry))
    }

    @Test func `leaving a stream stops the scrobble and saves progress`() {
        var machine = playingOnKS()
        #expect(machine.handle(.leave(.swap)) == [.scrobble(.stop), .persistProgress])
        #expect(machine.state == .idle)
        _ = machine.handle(.starting(.ksPlayer, .swap))
        #expect(machine.state == .starting(.swap))
    }

    /// KSPlayer marks the stream started and clears buffering in two writes.
    @Test func `the first frame arriving in two writes is not a stall`() {
        var machine = Machine()
        _ = machine.handle(.starting(.ksPlayer, .open))
        #expect(machine.handle(.reported(.ksPlayer, report(buffering: true, playing: false))) == [])
        #expect(machine.state == .starting(.open))
        #expect(machine.handle(.reported(.ksPlayer, report())) == [.scrobble(.start)])
    }

    /// A second surf while the first was still starting: the stream being left
    /// reports its first frame after the leave.
    @Test func `reports between streams are ignored`() {
        var machine = playingOnKS()
        _ = machine.handle(.leave(.swap))
        #expect(machine.handle(.reported(.ksPlayer, report())) == nil)
        #expect(machine.state == .idle)
    }

    @Test func `backgrounding saves progress and carries on`() {
        var machine = playingOnKS()
        #expect(machine.handle(.leave(.background)) == [.persistProgress])
        #expect(machine.state == .playing)
    }

    @Test func `nothing happens after dismissal`() {
        var machine = playingOnKS()
        #expect(machine.handle(.leave(.dismiss)) == [.scrobble(.stop), .persistProgress])
        #expect(machine.state == .closed)
        #expect(machine.handle(.reported(.ksPlayer, report(playing: false))) == nil)
        #expect(machine.handle(.leave(.background)) == nil)
    }

    @Test func `a Stalker link that won't resolve fails the session`() {
        var machine = Machine()
        _ = machine.handle(.resolving)
        #expect(machine.state == .resolving)
        _ = machine.handle(.resolveFailed)
        #expect(machine.state == .failed(.resolve))
        // Not the engine's overlay: the host shows its own for a resolve failure.
        #expect(!machine.showsFailure)
    }
}
