//
//  PlayerItemNavigation+Programmes.swift
//  Lume
//
//  The previous / next buttons for a catch-up programme: the programme before
//  it on the channel, and the one after — or the channel live, once the
//  programme after hasn't finished airing. Replaying the whole guide is what
//  the EPG is for; these are the steps the transport row can take in place.
//

import Foundation
import SwiftData

extension PlayerItemNavigation {
    /// Where a catch-up programme's "next" goes.
    nonisolated enum ProgrammeStep: Equatable {
        /// The following programme, from the archive.
        case replay(EPGSlot)
        /// The channel, live.
        case live
    }

    /// The pure rule, on plain values. "Previous" must have finished and still
    /// be in the archive. "Next" replays the following programme only once it
    /// has finished — otherwise (still airing, not started, or unknown to the
    /// guide) it catches the viewer up to the channel live, so it always has
    /// somewhere to go.
    nonisolated static func programmeSteps(
        previous: EPGSlot?,
        next: EPGSlot?,
        now: Date,
        replayable: (EPGSlot) -> Bool
    ) -> (previous: EPGSlot?, next: ProgrammeStep) {
        let previous = previous.flatMap { $0.end <= now && replayable($0) ? $0 : nil }
        let next: ProgrammeStep = if let next, next.end <= now, replayable(next) {
            .replay(next)
        } else {
            .live
        }
        return (previous, next)
    }

    /// Previous / next for a catch-up programme, resolved once per stream.
    static func programmeNeighbours(for media: PlayableMedia, now: Date = Date(), in context: ModelContext) -> Neighbours {
        guard let timeline = media.catchup,
              let stream = PlayerContentLookup.liveStream(timeline.streamID, in: context),
              let playlist = LiveChannelNavigator.playlist(for: stream, in: context)
        else { return Neighbours(axis: .programme, neighboursUnknown: true) }

        let adjacent = adjacentListings(channelId: stream.epgChannelId, around: timeline, in: context)
        let steps = programmeSteps(previous: adjacent.previous, next: adjacent.next, now: now) {
            stream.isCatchupAvailable(start: $0.start, now: now)
        }
        func replay(_ slot: EPGSlot) -> PlayableMedia? {
            PlayableMedia.catchup(stream: stream, playlist: playlist, programTitle: slot.title, start: slot.start, end: slot.end)
        }
        let next: PlayableMedia? = switch steps.next {
        case let .replay(slot): replay(slot)
        case .live: PlayableMedia.from(stream: stream, playlist: playlist, scope: media.channelScope)
        }
        return Neighbours(axis: .programme, previous: steps.previous.flatMap(replay), next: next)
    }

    /// The listings either side of the programme on screen: one indexed
    /// lookup each, on the channel's `end` / `start`.
    private static func adjacentListings(
        channelId: String?,
        around timeline: CatchupTimeline,
        in context: ModelContext
    ) -> (previous: EPGSlot?, next: EPGSlot?) {
        guard let channelId else { return (nil, nil) }
        let start = timeline.programmeStart
        let end = timeline.programmeEnd
        var before = FetchDescriptor<EPGListing>(
            predicate: #Predicate { $0.channelId == channelId && $0.end <= start },
            sortBy: [SortDescriptor(\.end, order: .reverse)]
        )
        before.fetchLimit = 1
        var after = FetchDescriptor<EPGListing>(
            predicate: #Predicate { $0.channelId == channelId && $0.start >= end },
            sortBy: [SortDescriptor(\.start)]
        )
        after.fetchLimit = 1
        let previous = (try? context.fetch(before))?.first.map(EPGSlot.init)
        let next = (try? context.fetch(after))?.first.map(EPGSlot.init)
        return (previous, next)
    }
}
