//
//  SportsPlayback.swift
//  Lume
//
//  Shared playback routing for the Sports Hub. Every fixture "Watch" action —
//  across the phone and tvOS home rails, the league screen and both hub screens —
//  resolves a tapped `ResolvedChannel` to a `PlayableMedia` the same way: find the
//  live stream in the viewer's own playlists, find its owning playlist, then build
//  the media. Presentation (the after-sheet delay, the macOS player window) stays
//  with each view, since it mutates that view's own state.
//

import SwiftData
import SwiftUI

enum SportsPlayback {
    /// The playable live stream a tapped channel points at, or `nil` when it is no
    /// longer present in the viewer's playlists.
    static func media(for channel: ResolvedChannel, in context: ModelContext) -> PlayableMedia? {
        guard let stream = PlayerContentLookup.liveStream(channel.stream.id, in: context),
              let playlist = LiveChannelNavigator.playlist(for: stream, in: context)
        else { return nil }
        return PlayableMedia.from(stream: stream, playlist: playlist)
    }

    /// A live game from its first minute, through the channel's catch-up
    /// archive — what Hide Scores leads with, since joining live gives the
    /// score away. The programme the resolver matched sets the start (else the
    /// fixture's kickoff), and its end is the fixture's expected end. `nil`
    /// when the game hasn't started or the channel can't replay it.
    static func fromStartMedia(
        for channel: ResolvedChannel,
        fixture: SportsFixture,
        in context: ModelContext,
        now: Date = Date()
    ) -> PlayableMedia? {
        let start = channel.matchedStart ?? fixture.startDate
        guard start <= now,
              let stream = PlayerContentLookup.liveStream(channel.stream.id, in: context),
              stream.isCatchupAvailable(start: start, now: now),
              let playlist = LiveChannelNavigator.playlist(for: stream, in: context)
        else { return nil }
        return PlayableMedia.catchup(
            stream: stream,
            playlist: playlist,
            programTitle: channel.matchedTitle ?? fixture.eventShortTitleOrMatchup,
            start: start,
            end: max(fixture.expectedEnd, now)
        )
    }
}

extension SportsFixture {
    /// "Bayern v Dortmund", or the event's own title.
    var eventShortTitleOrMatchup: String {
        if let home = home?.team, let away = away?.team {
            return "\(home.shortName) v \(away.shortName)"
        }
        return eventShortTitle
    }
}
