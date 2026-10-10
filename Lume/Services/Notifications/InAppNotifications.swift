import Foundation
import Observation

/// A skipped or cancelled refresh is not a failed refresh. Shared by the
/// playlist runner and guide service, not by their individual provider stages.
nonisolated enum SyncRefreshOutcome: Equatable {
    case succeeded, succeededWithWarnings, failed, skipped, cancelled

    var isSuccessful: Bool {
        self == .succeeded || self == .succeededWithWarnings
    }
}

/// In-app sync completions and programme reminders: no system notifications, persistence or
/// provider errors (which can contain connection credentials) in the message.
@Observable
final class InAppNotifications {
    static let shared = InAppNotifications()

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let subject: Subject
        let outcome: SyncRefreshOutcome?
        let profileToken: String
        var detail: String?
    }

    enum Subject: Equatable {
        case playlist(UUID, name: String)
        case guide
        case programme(String, title: String, channel: String)
        case message(title: String, detail: String)
    }

    private struct Host {
        let id: UUID
        let priority: Int
    }

    private(set) var pending: [Notice] = []
    private var hosts: [Host] = []

    /// Sheets and player covers need their own overlay, above the root one.
    /// Only the foremost registered host renders and expires the current toast.
    var presenterID: UUID? {
        hosts.enumerated().max {
            ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset)
        }?.element.id
    }

    func registerHost(_ id: UUID, priority: Int) {
        unregisterHost(id)
        hosts.append(Host(id: id, priority: priority))
    }

    func unregisterHost(_ id: UUID) {
        hosts.removeAll { $0.id == id }
    }

    func notice(for hostID: UUID, profileToken: String, isActive: Bool) -> Notice? {
        guard isActive, presenterID == hostID,
              let first = pending.first, first.profileToken == profileToken else { return nil }
        return first
    }

    func report(
        _ outcome: SyncRefreshOutcome,
        subject: Subject,
        startedUnder profileToken: String,
        currentProfileToken: String,
        detail: String? = nil
    ) {
        guard outcome.isSuccessful || outcome == .failed,
              profileToken == currentProfileToken else { return }
        // While the app is suspended, retain the latest result per source rather
        // than replaying hours of repeated scheduled refreshes on return.
        pending.removeAll { $0.subject == subject && $0.profileToken == profileToken }
        pending.append(Notice(subject: subject, outcome: outcome, profileToken: profileToken, detail: detail))
    }

    func retainProfile(_ token: String) {
        pending.removeAll { $0.profileToken != token }
    }

    func remind(id: String, title: String, channel: String, profileToken: String) {
        pending.append(Notice(subject: .programme(id, title: title, channel: channel), outcome: nil, profileToken: profileToken))
    }

    func message(title: String, detail: String, profileToken: String) {
        pending.append(Notice(subject: .message(title: title, detail: detail), outcome: nil, profileToken: profileToken))
    }

    /// An old host's cancelled timer must never dismiss the next message.
    func dismiss(_ id: UUID) {
        guard pending.first?.id == id else { return }
        pending.removeFirst()
    }
}
