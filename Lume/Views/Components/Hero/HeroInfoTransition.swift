import SwiftUI

/// Shared copy overlay owner. Paging, artwork and focus remain screen-owned.
@MainActor @Observable
final class HeroInfoTransition<ID: Hashable> {
    private(set) var displayedID: ID?
    private(set) var opacity: Double = 1
    @ObservationIgnored private var targetID: ID?
    @ObservationIgnored private var request = RequestToken()

    func reset(to id: ID?) {
        request = RequestToken()
        targetID = id
        displayedID = id
        opacity = 1
    }

    func reconcile(ids: [ID], selectedID: ID?) {
        guard let displayedID, ids.contains(displayedID), let targetID, ids.contains(targetID) else {
            reset(to: selectedID)
            return
        }
        select(selectedID)
    }

    /// Latest target wins, including returning to the outgoing slide mid-fade.
    func select(_ id: ID?) {
        guard let token = beginSelection(id) else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            opacity = 0
        } completion: {
            self.completeFade(token)
        }
    }

    func beginSelection(_ id: ID?) -> RequestToken? {
        guard targetID != id else { return nil }
        targetID = id
        request = RequestToken()
        return request
    }

    func completeFade(_ token: RequestToken) {
        guard request == token else { return }
        displayedID = targetID
        withAnimation(.easeOut(duration: 0.45)) {
            opacity = 1
        }
    }
}
