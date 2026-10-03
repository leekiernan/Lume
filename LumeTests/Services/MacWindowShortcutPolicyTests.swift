@testable import Lume
import Testing

struct MacWindowShortcutPolicyTests {
    @Test(arguments: [true, false])
    func `text editors keep escape and letter keys`(hasSheet: Bool) {
        #expect(!MacWindowShortcutPolicy.accepts(isEditingText: true, hasPresentedSheet: hasSheet))
    }

    @Test func `native sheets own their shortcuts`() {
        #expect(!MacWindowShortcutPolicy.accepts(isEditingText: false, hasPresentedSheet: true))
    }

    @Test func `browsing and video accept window commands`() {
        #expect(MacWindowShortcutPolicy.accepts(isEditingText: false, hasPresentedSheet: false))
    }
}
