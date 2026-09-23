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
            \.channelId, \.title, \.subtitle, \.category, \.listingDescription, \.start, \.end
        ] {
            #expect(props.contains(kept))
        }
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
