//
//  SportsPlaybackPresentationTests.swift
//  LumeTests
//

import Foundation
@testable import Lume
import Testing

@MainActor
struct SportsPlaybackPresentationTests {
    private func media(_ id: String) -> PlayableMedia {
        PlayableMedia(
            id: id, url: URL(string: "https://example.test/\(id).m3u8")!, title: id, subtitle: nil,
            posterURL: nil, kind: .live, startTime: 0, contentRef: .live(id)
        )
    }

    @Test func `with no sheet open, plays at once`() {
        var presentation = SportsPlaybackPresentation()
        presentation.play(media("a"), afterSheet: false)
        #expect(presentation.playing?.id == "a")
    }

    @Test func `from a closing sheet, waits for its dismissal`() {
        var presentation = SportsPlaybackPresentation()
        presentation.play(media("a"), afterSheet: true)
        #expect(presentation.playing == nil)
        presentation.sheetDidDismiss()
        #expect(presentation.playing?.id == "a")
    }

    @Test func `a sheet closing with nothing chosen plays nothing`() {
        var presentation = SportsPlaybackPresentation()
        presentation.sheetDidDismiss()
        #expect(presentation.playing == nil)
    }

    @Test func `direct playback supersedes an earlier pending sheet selection`() {
        var presentation = SportsPlaybackPresentation()
        presentation.play(media("a"), afterSheet: true)
        presentation.play(media("b"), afterSheet: false)
        presentation.sheetDidDismiss()
        #expect(presentation.playing?.id == "b")
        presentation.sheetDidDismiss()
        #expect(presentation.playing?.id == "b")
    }
}
