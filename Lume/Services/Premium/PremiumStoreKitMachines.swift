//
//  PremiumStoreKitMachines.swift
//  Lume
//
//  StoreKit has two independent lifecycles: product discovery may refresh at
//  any time, while purchase and restore present mutually-exclusive system work.
//  Keep those concerns separate so a catalog retry can never clear a checkout
//  spinner (or vice versa).
//

nonisolated struct PremiumProductLoadMachine: Equatable {
    enum State: Equatable {
        case idle
        case loading
        case available
        case unavailable
    }

    private(set) var state: State = .idle

    var isLoading: Bool {
        state == .loading
    }

    var hasFailed: Bool {
        state == .unavailable
    }

    @discardableResult
    mutating func begin() -> Bool {
        guard !isLoading else { return false }
        state = .loading
        return true
    }

    mutating func finish(hasProducts: Bool) {
        guard isLoading else { return }
        state = hasProducts ? .available : .unavailable
    }
}

nonisolated struct PremiumCheckoutMachine: Equatable {
    enum Operation: Equatable {
        case purchase(String)
        case restore
    }

    private(set) var activeOperation: Operation?

    var isWorking: Bool {
        activeOperation != nil
    }

    mutating func beginPurchase(productID: String) -> Operation? {
        begin(.purchase(productID))
    }

    mutating func beginRestore() -> Operation? {
        begin(.restore)
    }

    mutating func finish(_ operation: Operation) {
        guard activeOperation == operation else { return }
        activeOperation = nil
    }

    private mutating func begin(_ operation: Operation) -> Operation? {
        guard activeOperation == nil else { return nil }
        activeOperation = operation
        return operation
    }
}
