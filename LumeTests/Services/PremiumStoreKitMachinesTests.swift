//
//  PremiumStoreKitMachinesTests.swift
//  LumeTests
//

@testable import Lume
import Testing

/// A mutating call can't sit inside `#expect`/`#require` — the macro captures
/// its operands immutably — so each one runs first and its result is checked.
struct PremiumStoreKitMachinesTests {
    @Test func `product loading coalesces while in flight`() {
        var machine = PremiumProductLoadMachine()

        let first = machine.begin()
        #expect(first)
        #expect(machine.isLoading)
        let second = machine.begin()
        #expect(!second)

        machine.finish(hasProducts: true)
        #expect(!machine.isLoading)
        #expect(!machine.hasFailed)
    }

    @Test func `an empty product result is retryable`() {
        var machine = PremiumProductLoadMachine()

        let first = machine.begin()
        #expect(first)
        machine.finish(hasProducts: false)
        #expect(machine.hasFailed)
        let retry = machine.begin()
        #expect(retry)
        #expect(machine.isLoading)
    }

    @Test func `only one checkout operation may run at a time`() {
        var machine = PremiumCheckoutMachine()
        let purchase = machine.beginPurchase(productID: "monthly")

        #expect(purchase == .purchase("monthly"))
        let restore = machine.beginRestore()
        #expect(restore == nil)
        #expect(machine.isWorking)
    }

    @Test func `only the active checkout completion clears the operation`() throws {
        var machine = PremiumCheckoutMachine()
        let begun = machine.beginPurchase(productID: "monthly")
        let purchase = try #require(begun)

        machine.finish(.restore)
        #expect(machine.isWorking)

        machine.finish(purchase)
        #expect(!machine.isWorking)
        let restore = machine.beginRestore()
        #expect(restore == .restore)
    }
}
