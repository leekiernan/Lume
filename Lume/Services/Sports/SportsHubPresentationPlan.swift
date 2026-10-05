//
//  SportsHubPresentationPlan.swift
//  Lume
//
//  A render-time plan, not another load/selection owner. The existing hero and
//  resolution machines retain their lifecycle, context and request identities.
//

nonisolated struct SportsHubPresentationPlan {
    enum Surface {
        /// Keep the standard carousel concise on phones/tablets and Mac.
        case standard
        /// The remote-driven, full-screen showcase offers a longer browse.
        case television

        var carouselLimit: Int {
            switch self {
            case .standard: 5
            case .television: 8
            }
        }
    }

    let carousel: [SportsHeroSelectionMachine.Candidate]
    let carouselIDs: Set<String>
    let rowFixtures: [SportsFixture]
    let resolutionFixtures: [SportsFixture]

    init(
        fixtures: [SportsFixture],
        candidates: [SportsHeroSelectionMachine.Candidate],
        surface: Surface,
        highlights: [SportsFixture] = []
    ) {
        let carousel = Array(candidates.prefix(surface.carouselLimit))
        let carouselIDs = Set(carousel.map(\.id))
        self.carousel = carousel
        self.carouselIDs = carouselIDs
        rowFixtures = fixtures.filter { !carouselIDs.contains($0.id) }
        // Every displayed slide participates in the same guide-refresh request
        // as the rows, including highlights not in the followed fixture set.
        // Deduplicate without changing row-first publication order or snapshots.
        var seen: Set<String> = []
        resolutionFixtures = (fixtures + carousel.map(\.fixture) + highlights).filter { seen.insert($0.id).inserted }
    }

    func showsNoGames(groupsAreEmpty: Bool) -> Bool {
        groupsAreEmpty && carousel.isEmpty
    }
}
