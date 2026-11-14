import XCTest

@MainActor final class DayfoldUITests: XCTestCase {
    private func app(demo: Bool, id: String = UUID().uuidString) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [demo ? "--demo" : "--real", "--ui-test-id", id]
        app.launch(); return app
    }
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testWelcomeAndMissingConfiguration() {
        let app = app(demo: false)
        XCTAssertTrue(app.buttons["Explore Demo"].waitForExistence(timeout: 30))
        capture("account-setup", app: app)
        app.buttons["Connect Google Account"].click()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS 'OAuth'")).firstMatch.exists)
        app.alerts.buttons["OK"].click()
    }
    func testCalendarViewsAndDurableDraft() {
        let id = UUID().uuidString
        let app = app(demo: true, id: id)
        XCTAssertTrue(app.buttons["Month"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS 'Focus'")).firstMatch.waitForExistence(timeout: 30))
        capture("week", app: app)
        app.buttons["Month"].click(); capture("month", app: app)
        app.buttons["Agenda"].click(); capture("agenda", app: app)
        app.typeKey("n", modifierFlags: .command)
        let title = app.textFields["event-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.click(); title.typeText("UI persistence check")
        app.buttons["Save Draft"].click(); capture("editor", app: app)
        app.terminate(); app.launch()
        XCTAssertTrue(app.outlines.firstMatch.waitForExistence(timeout: 20) || app.windows.firstMatch.exists)
        let pending = app.staticTexts["Pending Changes"].firstMatch
        if pending.waitForExistence(timeout: 10) { pending.click() }
        else { app.buttons["Pending Changes"].firstMatch.click() }
        XCTAssertTrue(app.staticTexts["UI persistence check"].waitForExistence(timeout: 15))
        app.buttons["Resume"].firstMatch.click()
        XCTAssertTrue(app.textFields["event-title"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["event-title"].value as? String, "UI persistence check")
        app.buttons["save-event"].click()
        XCTAssertFalse(app.sheets.firstMatch.waitForNonExistence(timeout: 10) == false)
        app.typeKey("1", modifierFlags: .command)
        app.typeKey("t", modifierFlags: .command)
        app.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'UI persistence check,'")).firstMatch.waitForExistence(timeout: 20))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertNotEqual(app.state, .notRunning, "Closing the last window must leave the companion running")
    }
    func testConflictRecoveryUI() {
        let app = app(demo: true)
        let event = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Focus · Dayfold' AND label CONTAINS 'Studio · Studio,'")).firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 30)); event.click()
        let simulate = app.buttons["Simulate conflicting edits"].firstMatch
        if simulate.waitForExistence(timeout: 5) { simulate.click() }
        else { app.links["Simulate conflicting edits"].firstMatch.click() }
        XCTAssertTrue(app.buttons["Keep Google version"].waitForExistence(timeout: 20))
        capture("conflict", app: app)
        app.buttons["Keep Google version"].click()
        XCTAssertTrue(app.buttons["Keep Google version"].waitForNonExistence(timeout: 10))
    }
}
