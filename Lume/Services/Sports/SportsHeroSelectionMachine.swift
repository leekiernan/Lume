//
//  SportsHeroSelectionMachine.swift
//  Lume
//
//  Stable presentation ownership for the Sports Hub hero. Score snapshots and
//  channel resolution arrive independently, often in partial passes; neither
//  should make the hero or tvOS focus jump between otherwise valid fixtures.
//

/// Keeps one Sports Hub hero stable while its candidate list fills in.
///
/// The caller supplies candidates already grouped into semantic tiers. Channel
/// availability chooses the best fixture *within* a tier, never lets a distant
/// highlight displace a live game. Once displayed, a valid hero remains until
/// it disappears or a higher semantic tier becomes available.
nonisolated struct SportsHeroSelectionMachine: Equatable {
    enum Tier: Int, CaseIterable, Comparable {
        /// A live game involving a followed team.
        case followedLive
        /// Another live game in the active hub scope.
        case live
        /// The next game for the selected league or a followed team.
        case primaryUpcoming
        /// The strongest wider "Big This Week" event.
        case highlight
        /// Another upcoming fixture in a followed league.
        case contextualUpcoming

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct Candidate: Identifiable, Equatable {
        let fixture: SportsFixture
        let tier: Tier
        /// A non-empty resolver answer after the active profile's restrictions.
        let isAvailable: Bool

        var id: String {
            fixture.id
        }
    }

    /// The `.task(id:)` identity for reconciling: the context and every
    /// candidate's id, tier and availability.
    static func reconcileKey(context: String, candidates: [Candidate]) -> String {
        let token = candidates.map { "\($0.id):\($0.tier.rawValue):\($0.isAvailable)" }.joined(separator: ",")
        return "\(context)|\(token)"
    }

    private(set) var selectedID: String?
    private var context: String?

    /// The hero to render now. A context mismatch deliberately falls back to
    /// the current preferred candidate before the view's task records it, so a
    /// scope or date-segment switch never flashes the previous hero.
    func displayed(in candidates: [Candidate], context: String) -> Candidate? {
        if self.context == context,
           let selectedID,
           let selected = candidates.first(where: { $0.id == selectedID })
        {
            return selected
        }
        return Self.preferred(in: candidates)
    }

    /// The carousel order for the current render. Its lead page is the stable
    /// semantic selection; the remaining valid candidates stay available as
    /// neighbouring pages instead of replacing the one a viewer is reading.
    func carouselCandidates(in candidates: [Candidate], context: String) -> [Candidate] {
        guard let selected = displayed(in: candidates, context: context) else { return [] }
        return [selected] + candidates.filter { $0.id != selected.id }
    }

    /// Records the currently displayed hero after a view update. A same-tier
    /// resolver result cannot replace a valid hero under the viewer; only a
    /// higher semantic tier can promote over it.
    mutating func reconcile(candidates: [Candidate], context: String) {
        guard self.context == context else {
            self.context = context
            selectedID = Self.preferred(in: candidates)?.id
            return
        }
        guard let preferred = Self.preferred(in: candidates) else {
            selectedID = nil
            return
        }
        guard let selectedID,
              let selected = candidates.first(where: { $0.id == selectedID })
        else {
            selectedID = preferred.id
            return
        }
        if preferred.tier < selected.tier {
            self.selectedID = preferred.id
        }
    }

    private static func preferred(in candidates: [Candidate]) -> Candidate? {
        for tier in Tier.allCases {
            let candidatesInTier = candidates.filter { $0.tier == tier }
            if let available = candidatesInTier.first(where: \.isAvailable) {
                return available
            }
            if let first = candidatesInTier.first {
                return first
            }
        }
        return nil
    }
}
