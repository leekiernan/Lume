import Foundation

/// Application order for keychain-backed credential merges only. Catalog and
/// profile verdicts have different resolution/deletion authority and do not
/// belong here. Store saves and disconnect acknowledgement stay in the engine.
nonisolated enum CredentialMergeApplication {
    struct Effects: Equatable {
        var pushed = 0
        var pulled = 0
        var pending = 0
        var deletionPushed = false
    }

    static func apply<Value>(
        _ verdict: MergeVerdict<Value>,
        writeLocal: (Value?) -> Bool,
        writeCloud: (Value?) -> Void,
        recordShadow: (Value?) -> Void
    ) -> Effects {
        switch verdict {
        case .noChange:
            return Effects()
        case let .pushToCloud(value):
            writeCloud(value)
            recordShadow(value)
            return Effects(pushed: 1, deletionPushed: value == nil)
        case let .pullToLocal(value):
            guard writeLocal(value) else { return Effects(pending: 1) }
            recordShadow(value)
            return Effects(pulled: 1)
        case let .writeBoth(value):
            // Never baseline or export a rotating token the keychain rejected.
            guard writeLocal(value) else { return Effects(pending: 1) }
            writeCloud(value)
            recordShadow(value)
            return Effects(pushed: 1, pulled: 1)
        }
    }
}
