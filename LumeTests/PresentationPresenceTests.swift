@testable import Lume
import SwiftUI
import Testing

struct PresentationPresenceTests {
    @Test func `presence follows the current target and dismissal clears it`() {
        var target: String? = "first"
        let source = Binding(get: { target }, set: { target = $0 })
        let presence = source.presentationPresence()
        #expect(presence.wrappedValue)
        target = "replacement"
        presence.wrappedValue = true
        #expect(target == "replacement")
        presence.wrappedValue = false
        #expect(target == nil)
        #expect(!presence.wrappedValue)
    }

    @Test func `presenting cannot create a missing target and binding remains reusable`() {
        var target: Int?
        let source = Binding(get: { target }, set: { target = $0 })
        let presence = source.presentationPresence()
        presence.wrappedValue = true
        #expect(target == nil)
        target = 42
        #expect(presence.wrappedValue)
        presence.wrappedValue = false
        target = 7
        #expect(presence.wrappedValue)
        #expect(target == 7)
    }
}
