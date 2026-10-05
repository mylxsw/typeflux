import XCTest

final class ChatPolishTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEnglishSettingsAndAccountHaveCompactRows() {
        let app = XCUIApplication()
        app.launchArguments = ["--synthetic-preview", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.sidebar.open"].waitForExistence(timeout: 10))
        openHistory(app)
        app.buttons["chat.account"].tap()
        let auto = app.buttons["settings.appearance.system"]
        XCTAssertTrue(auto.waitForExistence(timeout: 5))
        XCTAssertEqual(auto.label, "System")
        XCTAssertFalse(app.staticTexts["Automatic"].exists)
        XCTAssertLessThanOrEqual(auto.frame.height, 34)
        screenshot(app, "gul212-settings-en-light")
        app.buttons["settings.appearance.dark"].tap()
        screenshot(app, "gul212-settings-en-dark")
        app.buttons["settings.account"].tap()
        let account = app.scrollViews["account.root"]
        let name = account.staticTexts["account.name"]
        let email = account.staticTexts["account.email"]
        let status = account.staticTexts["account.status"]
        let plan = account.staticTexts["account.plan"]
        XCTAssertTrue(plan.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(email.frame.minY, name.frame.maxY)
        XCTAssertGreaterThan(status.frame.minY, email.frame.maxY)
        XCTAssertGreaterThan(plan.frame.minY, status.frame.maxY)
        XCTAssertLessThan(plan.frame.minY - status.frame.maxY, 60)
        XCTAssertLessThan(plan.frame.maxY - name.frame.minY, 260)
        screenshot(app, "gul212-account-en-dark")
    }

    @MainActor
    func testWholeReplySelectionIncludesParagraphsTableAndCode() {
        let app = XCUIApplication()
        app.launchArguments = ["--synthetic-preview", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.sidebar.open"].waitForExistence(timeout: 10))
        openHistory(app)
        app.buttons["chat.history.preview"].tap()
        let select = app.buttons["chat.select.answer"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        if !select.isHittable {
            app.swipeUp()
        }
        select.tap()
        let text = app.textViews["chat.selection.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        let value = text.value as? String ?? ""
        XCTAssertTrue(value.contains("Start with three small things:"))
        XCTAssertTrue(value.contains("1.  Leave your phone"))
        XCTAssertTrue(value.contains("Habit | Time | Why"))
        XCTAssertTrue(value.contains("let priority = \"One meaningful thing\""))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        text.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 60, dy: 10)).press(forDuration: 1.2)
        let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Copy")).firstMatch
        if !copy.waitForExistence(timeout: 5) {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "selection-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            screenshot(app, "selection-menu-missing")
            XCTFail("Selecting a word must expose the native Copy action")
            return
        }
        screenshot(app, "gul212-native-selection")
        app.buttons["chat.selection.done"].tap()
        XCTAssertTrue(select.waitForExistence(timeout: 5))
    }

    @MainActor
    func testLongEmailAndLargeTypeAccountLayout() {
        let app = XCUIApplication()
        app.launchArguments = ["--synthetic-preview", "--synthetic-long-email", "-AppleLanguages", "(en)",
                               "-AppleLocale", "en_US", "-UIPreferredContentSizeCategoryName",
                               "UICTContentSizeCategoryXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.sidebar.open"].waitForExistence(timeout: 10))
        openHistory(app)
        app.buttons["chat.account"].tap()
        app.buttons["settings.account"].tap()
        let email = app.staticTexts["account.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        XCTAssertEqual(email.label, "very.long.account.address.for.layout.testing@example.invalid")
        XCTAssertGreaterThan(email.frame.height, 40)
        XCTAssertGreaterThanOrEqual(email.frame.minX, 16)
        XCTAssertLessThanOrEqual(email.frame.maxX, app.frame.maxX - 16)
        let status = app.staticTexts["account.status"]
        XCTAssertGreaterThan(status.frame.minY, email.frame.maxY)
        XCTAssertLessThan(status.frame.minY - email.frame.maxY, 70)
        screenshot(app, "gul212-account-long-email-large-type")
    }

    @MainActor
    private func openHistory(_ app: XCUIApplication) {
        app.buttons["chat.sidebar.open"].tap()
        XCTAssertTrue(app.buttons["chat.new"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
