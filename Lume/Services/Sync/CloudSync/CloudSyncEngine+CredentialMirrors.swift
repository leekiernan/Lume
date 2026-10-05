import Foundation
import SwiftData

extension CloudSyncEngine {
    /// Tracker account mirrors share validity/deduplication mechanics, but keep
    /// separate models and timestamp/token mappings. This runs only after the
    /// provider's keychain read is known to be available.
    func fetchCredentialMirror<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>,
        isValid: (Model) -> Bool,
        updatedAt: (Model) -> Date
    ) throws -> Model? {
        var winner: Model?
        for record in try cloudContext.fetch(descriptor) {
            guard isValid(record) else {
                cloudContext.delete(record)
                continue
            }
            winner = dedupe(record, against: winner, updatedAt: updatedAt)
        }
        return winner
    }
}
