import Foundation
@testable import Lume
import Testing

@MainActor
struct PlayerChromeRoutingTests {
    @Test func `player menu routing retains priority and lazy remote handoff`() {
        let chrome = PlayerChromeController()
        var actions: [String] = []
        var claims = 0
        func menu(failed: Bool = false, browser: Bool = false, panel: Bool = false, claimed: Bool = false) {
            chrome.menu(.init(failed: failed, browserOpen: browser, panelOpen: panel),
                        claimsBack: { claims += 1; return claimed }, closeBrowser: { actions.append("browser") },
                        closePanel: { actions.append("panel") }, closePlayer: { actions.append("player") })
        }
        menu(failed: true, browser: true, panel: true)
        menu(browser: true, panel: true)
        menu(panel: true)
        menu()
        #expect(actions == ["player", "browser", "panel"])
        #expect(!chrome.isVisible)
        #expect(claims == 0)
        menu(claimed: true)
        #expect(actions.count == 3 && claims == 1)
        menu()
        #expect(actions.last == "player" && claims == 2)
    }
}
