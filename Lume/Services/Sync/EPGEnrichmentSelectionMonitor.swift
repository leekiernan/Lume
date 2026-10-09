import CryptoKit
import Foundation
import OSLog
import SwiftData

/// Observe committed category changes, including profile/iCloud changes and
/// bulk hide/show, rather than coupling refreshes to one settings screen.
/// A checkpoint is written only after publication, so interrupted work survives launch.
final class EPGEnrichmentSelectionMonitor {
    private static let checkpointKey = "lume.epgEnrichment.categorySelection.v1"
    private let container: ModelContainer
    private let defaults: UserDefaults
    private let onChange: () -> Void
    private var observer: NSObjectProtocol?
    private var checkTask: Task<Void, Never>?
    private(set) var fingerprint: String?

    init(container: ModelContainer, defaults: UserDefaults = .standard, onChange: @escaping () -> Void) {
        self.container = container
        self.defaults = defaults
        self.onChange = onChange
        fingerprint = defaults.string(forKey: Self.checkpointKey)
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleCheck() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        checkTask?.cancel()
    }

    @discardableResult
    func check(notify: Bool = true) -> Bool {
        do {
            let live = "live"
            var query = FetchDescriptor<Category>(predicate: #Predicate { $0.typeRaw == live })
            query.propertiesToFetch = [\.id, \.name, \.typeRaw, \.isHidden, \.epgEnrichmentEnabled]
            let ids = try ModelContext(container).fetch(query).filter {
                EPGEnrichmentCategories.isEligible(name: $0.name, type: $0.typeRaw, hidden: $0.isHidden, override: $0.epgEnrichmentEnabled)
            }.map(\.id).sorted()
            let enabled = defaults.bool(forKey: EPGEnrichmentSettings.enabledKey)
            let data = try JSONEncoder().encode([enabled ? "on" : "off"] + ids)
            let next = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard next != fingerprint else { return false }
            let wasUnconfigured = fingerprint == nil
            fingerprint = next
            if wasUnconfigured, !enabled {
                published(next)
            } else {
                if notify { onChange() }
                return true
            }
        } catch {
            Logger.database.warning("EPG category selection read failed: \(error.localizedDescription, privacy: .public)")
        }
        return false
    }

    func published(_ fingerprint: String?) {
        if let fingerprint { defaults.set(fingerprint, forKey: Self.checkpointKey) }
    }

    private func scheduleCheck() {
        // One scan of the small category table after a burst of catalog saves,
        // not one per programme or live-stream import batch.
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            self?.check()
        }
    }
}
