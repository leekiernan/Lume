//
//  EpisodeOverlayMachineTests.swift
//  LumeTests
//
//  Which episode affordance shows when: the zone arithmetic over the playback
//  clock, and the machine's rules for settings, the controls, dismissal, a
//  press and auto-advance.
//

import Foundation
@testable import Lume
import Testing

struct EpisodeOverlayMachineTests {
    private let intro = IntroSegments.Segment(start: 237, end: 259)
    private let recap = IntroSegments.Segment(start: 10, end: 40)

    private var everything: EpisodeOverlayMachine.Config {
        .init(skipButton: true, nextButton: true, autoAdvance: true, hasNextEpisode: true)
    }

    private func machine(_ config: EpisodeOverlayMachine.Config? = nil) -> EpisodeOverlayMachine {
        var machine = EpisodeOverlayMachine()
        _ = machine.handle(.configure(config ?? everything))
        return machine
    }

    // MARK: - Zones

    @Test func `the playhead maps onto the episode's windows`() {
        let segments = IntroSegments(intro: intro, recap: recap, outro: nil)
        func zone(_ time: TimeInterval) -> EpisodeOverlayMachine.Zone {
            EpisodeOverlayMachine.zone(current: time, duration: 3000, segments: segments)
        }
        #expect(zone(0) == .unknown)
        #expect(zone(20) == .recap(recap))
        #expect(zone(240) == .intro(intro))
        #expect(zone(259) == .content)
        #expect(zone(2800) == .outro) // past 90%
        #expect(zone(2998) == .ending)
    }

    @Test func `a window under five seconds is no window`() {
        let blip = IntroSegments(intro: .init(start: 100, end: 103), recap: nil, outro: nil)
        #expect(EpisodeOverlayMachine.zone(current: 101, duration: 3000, segments: blip) == .content)
    }

    @Test func `an unknown duration never reaches the outro or the end`() {
        #expect(EpisodeOverlayMachine.zone(current: 5000, duration: 0, segments: nil) == .content)
    }

    // MARK: - Offers

    @Test func `entering the intro offers the skip, leaving withdraws it`() {
        var machine = machine()
        _ = machine.handle(.zone(.intro(intro)))
        #expect(machine.activeOffer == .skipIntro(intro))
        _ = machine.handle(.zone(.content))
        #expect(machine.activeOffer == nil)
    }

    @Test func `skipping seeks to the end of the window`() {
        var machine = machine()
        _ = machine.handle(.zone(.intro(intro)))
        let effects = machine.handle(.activate)
        #expect(effects == [.seek(259)])
        #expect(machine.state == .none)
    }

    @Test func `a dismissed skip stays down for its window`() {
        var machine = machine()
        _ = machine.handle(.zone(.intro(intro)))
        _ = machine.handle(.dismiss)
        #expect(machine.activeOffer == nil)
        #expect(machine.state == .dismissed(.skipIntro(intro)))
    }

    @Test func `the skip setting off offers nothing`() {
        var config = everything
        config.skipButton = false
        var machine = machine(config)
        _ = machine.handle(.zone(.intro(intro)))
        #expect(machine.state == .none)
    }

    @Test func `a setting switched off mid-offer withdraws it`() {
        var machine = machine()
        _ = machine.handle(.zone(.intro(intro)))
        var config = everything
        config.skipButton = false
        _ = machine.handle(.configure(config))
        #expect(machine.state == .none)
    }

    // MARK: - Next episode

    @Test func `the outro offers the next episode`() {
        var machine = machine()
        _ = machine.handle(.zone(.outro))
        #expect(machine.activeOffer == .nextEpisode)
        let played = machine.handle(.activate)
        #expect(played == [.playNext])
    }

    @Test func `no next episode, no offer`() {
        var config = everything
        config.hasNextEpisode = false
        var machine = machine(config)
        _ = machine.handle(.zone(.outro))
        #expect(machine.state == .none)
    }

    @Test func `a dismissed next episode stays down for the episode`() {
        var machine = machine()
        _ = machine.handle(.zone(.outro))
        _ = machine.handle(.dismiss)
        _ = machine.handle(.zone(.content)) // seeked back
        _ = machine.handle(.zone(.outro))
        #expect(machine.state == .dismissed(.nextEpisode))
    }

    @Test func `a new episode clears the dismissal`() {
        var machine = machine()
        _ = machine.handle(.zone(.outro))
        _ = machine.handle(.dismiss)
        _ = machine.handle(.reset)
        _ = machine.handle(.zone(.content))
        _ = machine.handle(.zone(.outro))
        #expect(machine.activeOffer == .nextEpisode)
    }

    // MARK: - Auto-advance

    @Test func `the ending advances once`() {
        var machine = machine()
        let first = machine.handle(.zone(.ending))
        #expect(first == [.playNext])
        _ = machine.handle(.zone(.outro))
        let again = machine.handle(.zone(.ending))
        #expect(again.isEmpty)
    }

    @Test func `auto-advance off, or nothing next, stays put`() {
        var off = everything
        off.autoAdvance = false
        var machine = machine(off)
        let withAutoAdvanceOff = machine.handle(.zone(.ending))
        #expect(withAutoAdvanceOff.isEmpty)

        var noNext = everything
        noNext.hasNextEpisode = false
        machine = self.machine(noNext)
        let withNothingNext = machine.handle(.zone(.ending))
        #expect(withNothingNext.isEmpty)
    }
}
