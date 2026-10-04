import Foundation

/// Opaque, process-local identity for one request or invalidation epoch.
/// Mint a fresh token rather than using the query key: A → B → A must not
/// revive the first A, and a recreated owner must not reuse an old counter.
///
/// This carries no loading state, scope, cancellation or task ownership. Each
/// domain machine decides when to replace it and which lane may accept it.
/// Keep domain Request wrappers when they also carry payload or distinguish
/// APIs; never persist this as a catalog/cache/profile identifier.
nonisolated struct RequestToken: Equatable, Hashable {
    private let identity: UUID

    init() {
        identity = UUID()
    }
}
