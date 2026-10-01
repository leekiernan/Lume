//
//  SportsQueryShapeTests.swift
//  LumeTests
//
//  The same performance-contract shape as BrowseQueryShapeTests — a bounded
//  fetch, a probe with no sort — for the two fetches the Sports Hub's channel
//  resolver added.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct SportsQueryShapeTests {
    /// The sports resolver's EPG fetch must be bounded by channel ids and the
    /// kickoff window so it never turns into the time-only guide scan the
    /// loaders exist to avoid. It is the one guide fetch that reads
    /// `listingDescription`, because conference programmes list their games
    /// only in the body.
    @Test func `sports resolver EPG fetch is scoped and includes the description`() {
        let descriptor = SportsChannelResolver.epgCandidateDescriptor(
            channelIds: ["ch1", "ch2"], windowStart: .now, windowEnd: .now.addingTimeInterval(3600)
        )
        #expect(descriptor.predicate != nil, "the guide fetch must be bounded, not a full scan")
        let props = descriptor.propertiesToFetch
        #expect(!props.isEmpty, "a partial fetch, not the whole row")
        // Unlike the guide loaders, this fetch needs the description: a
        // conference programme names its games only there. The kickoff window
        // and channel-id bound keep the row count small enough to afford it.
        for kept: PartialKeyPath<EPGListing> in [
            \.channelId, \.title, \.subtitle, \.listingDescription, \.start, \.end
        ] {
            #expect(props.contains(kept))
        }
        // Matching never reads the categories; keep the column out of the rows.
        #expect(!props.contains(\EPGListing.category))
    }

    /// No SQL sort: each window's rows would go through a temp B-tree no index
    /// serves. The resolver orders each channel's few rows in Swift.
    @Test func `sports resolver EPG fetch leaves ordering to Swift`() {
        let descriptor = SportsChannelResolver.epgCandidateDescriptor(
            channelIds: ["ch1"], windowStart: .now, windowEnd: .now.addingTimeInterval(3600)
        )
        #expect(descriptor.sortBy.isEmpty)
    }

    /// The guide is read around each kickoff, not across the whole span from
    /// the first to the last: games a day apart read two windows, and games
    /// close enough to overlap read one.
    @Test func `kickoff windows merge only where they overlap`() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func fixture(_ id: String, at offset: TimeInterval) -> SportsFixture {
            SportsFixture(
                id: id, leagueId: "l", leagueName: "L", leagueAbbreviation: "L",
                startDate: base.addingTimeInterval(offset), status: SportsFixtureStatus(state: .scheduled),
                home: SportsCompetitor(team: SportsTeam(leagueId: "l", teamId: "h", name: "H", shortName: "H", abbreviation: "")),
                away: SportsCompetitor(team: SportsTeam(leagueId: "l", teamId: "a", name: "A", shortName: "A", abbreviation: ""))
            )
        }
        let windows = SportsChannelResolver.guideWindows(for: [
            fixture("late", at: 86400), fixture("early", at: 0), fixture("alongside", at: 1800)
        ])
        #expect(windows.count == 2)
        #expect(windows[0].lowerBound == base.addingTimeInterval(-SportsMatcher.leadTime))
        #expect(windows[0].upperBound == base.addingTimeInterval(1800 + SportsMatcher.lateStart))
        #expect(windows[1].lowerBound == base.addingTimeInterval(86400 - SportsMatcher.leadTime))
    }

    /// The candidate-channel fetch must run its exclusion (hidden channels and
    /// restricted categories) as a `#Predicate` in SQLite, not by fetching every
    /// channel and filtering in Swift afterwards.
    @Test func `sports resolver channel fetch filters in SQLite`() {
        let descriptor = SportsChannelResolver.candidateStreamDescriptor(
            restriction: ContentRestriction(hiddenCategoryIDs: ["hidden-cat"])
        )
        #expect(descriptor.predicate != nil)
    }
}
