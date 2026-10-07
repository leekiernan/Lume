import Foundation
import Observation

/// Full tracker membership, not the catalog-matched subset displayed in a rail.
/// Account and revision guards prevent an old fetch undoing a newer heart tap.
@MainActor
@Observable
final class TrackerWatchlistMembership {
    private(set) var account: String?
    private(set) var revision = UUID()
    private var targets: Set<TrackerMutation.Target> = []
    private var refreshedAt: Date?

    var needsRefresh: Bool {
        refreshedAt.map { Date().timeIntervalSince($0) > 60 } ?? true
    }

    func contains(_ target: TrackerMutation.Target, account: String?) -> Bool {
        guard let account, self.account == account else { return false }
        return targets.contains(target)
    }

    func reset(account: String?) {
        guard self.account != account else { return }
        self.account = account
        targets = []
        refreshedAt = nil
        revision = UUID()
    }

    func apply(_ target: TrackerMutation.Target, isPresent: Bool) {
        if isPresent { targets.insert(target) } else { targets.remove(target) }
        revision = UUID()
    }

    func invalidate() {
        // A read begun before delivery can contain the server's old state even
        // after the outbox has acknowledged the write. Reject that read too.
        revision = UUID()
        refreshedAt = nil
    }

    func replace(with targets: Set<TrackerMutation.Target>, account: String, revision: UUID) {
        guard self.account == account, self.revision == revision else { return }
        self.targets = targets
        refreshedAt = Date()
    }
}
