import XCTest

/// Render the actual native lists and navigation chrome, not just isolated
/// labels. Screenshots are evidence for review; geometry and navigation are
/// assertions so a later shared-control change cannot silently regress them.
@MainActor
final class SettingsPresentationTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLibraryControlsInDarkAppearance() {
        checkLibraryPresentation(appearance: "dark", accessibilityText: false)
    }

    func testLibraryControlsWithAccessibilityTextInLightAppearance() {
        checkLibraryPresentation(appearance: "light", accessibilityText: true)
    }

    func testLibraryControlsWithAccessibilityTextInDarkAppearance() {
        checkLibraryPresentation(appearance: "dark", accessibilityText: true)
    }

    private func checkLibraryPresentation(appearance: String, accessibilityText: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-app.appearance", appearance, "-AppleLanguages", "(en)"]
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", accessibilityText
            ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.openSettingsSheet(), "Settings sheet did not open")
        capture(app, name: "Settings \(appearance) \(accessibilityText ? "accessibility" : "standard")")

        let library = app.cells.buttons["Library"].firstMatch
        XCTAssertTrue(scrollUntilHittable([library], in: app), "Library row never appeared")
        library.tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
        capture(app, name: "Library top \(appearance) \(accessibilityText ? "accessibility" : "standard")")

        for title in ["Home", "Movies", "Series", "Live TV", "Sports"] {
            // Scope to list cells: the sheet leaves identically named tab-bar
            // buttons in the accessibility tree behind it.
            let link = app.cells.buttons[title].firstMatch
            let toggle = app.cells.switches[title].firstMatch
            XCTAssertTrue(scrollUntilHittable([link, toggle], in: app), "Missing \(title) controls.\n\(app.debugDescription)")
            // Native switches have their own intrinsic size. The surrounding
            // destination must remain a full-height, distinct interaction.
            XCTAssertTrue(toggle.exists, "Missing independently labelled \(title) switch")
            XCTAssertTrue(link.isHittable, "\(title) destination is inaccessible")
            XCTAssertTrue(toggle.isHittable, "\(title) switch is inaccessible")
            XCTAssertGreaterThanOrEqual(link.frame.height, 44)
            if accessibilityText {
                XCTAssertGreaterThan(link.frame.height, 44, "Accessibility text did not grow")
                XCTAssertLessThanOrEqual(link.frame.maxY, toggle.frame.minY + 1,
                                         "\(title) destination overlaps the switch below it")
            } else {
                XCTAssertLessThanOrEqual(link.frame.maxX, toggle.frame.minX + 1,
                                         "\(title) destination overlaps its switch")
            }
            XCTAssertLessThanOrEqual(toggle.frame.maxX, app.frame.maxX)
        }
        capture(app, name: "Library \(appearance) \(accessibilityText ? "accessibility" : "standard")")

        let liveTV = app.cells.buttons["Live TV"].firstMatch
        // At maximum text sizes the earlier rows are now above the viewport.
        for _ in 0 ..< 5 {
            if fullyVisible(liveTV, in: app) { break }
            app.swipeDown()
        }
        XCTAssertTrue(fullyVisible(liveTV, in: app))
        liveTV.tap()
        XCTAssertTrue(app.navigationBars["Live TV"].waitForExistence(timeout: 10))
        let categories = app.buttons["Categories"].firstMatch
        XCTAssertTrue(categories.waitForExistence(timeout: 10))
        XCTAssertTrue(categories.isHittable)
        capture(app, name: "Live TV categories \(appearance) \(accessibilityText ? "accessibility" : "standard")")

        app.navigationBars["Live TV"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
    }

    private func scrollUntilHittable(_ elements: [XCUIElement], in app: XCUIApplication) -> Bool {
        for _ in 0 ..< 15 {
            if elements.allSatisfy({ fullyVisible($0, in: app) }) { return true }
            app.swipeUp()
        }
        return elements.allSatisfy { fullyVisible($0, in: app) }
    }

    private func fullyVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists, element.isHittable else { return false }
        // isHittable can include a sliver beneath the translucent navigation
        // bar. That isn't a reliable place for XCUITest's centre-point tap.
        let top = app.navigationBars.firstMatch.frame.maxY
        let frame = element.frame
        return frame.minY >= top && frame.maxY <= app.frame.maxY - 16
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
