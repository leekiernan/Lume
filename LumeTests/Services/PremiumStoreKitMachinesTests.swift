//
//  PremiumStoreKitMachinesTests.swift
//  LumeTests
//

@testable import Lume
import Testing

struct PremiumStoreKitMachinesTests {
    @Test func `product loading coalesces while in flight`() {
        var machine = PremiumProductLoadMachine()

        #expect(machine.begin())
        #expect(machine.isLoading)
        #expect(!machine.begin())

        machine.finish(hasProducts: true)
        #expect(!machine.isLoading)
        #expect(!machine.hasFailed)
    }

    @Test func `an empty product result is retryable`() {
        var machine = PremiumProductLoadMachine()

        #expect(machine.begin())
        machine.finish(hasProducts: false)
        #expect(machine.hasFailed)
        #expect(machine.begin())
        #expect(machine.isLoading)
    }

    @Test func `only one checkout operation may run at a time`() {
        var machine = PremiumCheckoutMachine()
        let purchase = machine.beginPurchase(productID: "monthly")

        #expect(purchase == .purchase("monthly"))
        #expect(machine.beginRestore() == nil)
        #expect(machine.isWorking)
    }

    @Test func `only the active checkout completion clears the operation`() throws {
        var machine = PremiumCheckoutMachine()
        let purchase = try #require(machine.beginPurchase(productID: "monthly"))

        machine.finish(.restore)
        #expect(machine.isWorking)

        machine.finish(purchase)
        #expect(!machine.isWorking)
        #expect(machine.beginRestore() == .restore)
    }
}
