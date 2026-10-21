import XCTest

final class ChatPolishTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppIconSettingsShowAllStylesInBothLanguages() {
        for language in ["en", "zh-Hans"] {
            let app = XCUIApplication()
            app.launchArguments = ["--synthetic-preview", "-AppleLanguages", "(\(language))"]
            app.launch()
            XCTAssertTrue(app.buttons["chat.sidebar.open"].waitForExistence(timeout: 10))
            openHistory(app)
            app.buttons["chat.account"].tap()
            let entry = app.buttons["settings.appIcon"]
            XCTAssertTrue(entry.waitForExistence(timeout: 5))
            if !entry.isHittable { app.swipeUp() }
            entry.tap()
            let first = app.buttons["settings.appIcon.glassFrosted"]
            XCTAssertTrue(first.waitForExistence(timeout: 5))
            XCTAssertEqual(first.label, language == "en" ? "Frosted glass" : "磨砂玻璃")
            screenshot(app, "gul447-icons-" + language)
            let last = app.buttons["settings.appIcon.hairyPuppet"]
            if !last.isHittable { app.swipeUp() }
            XCTAssertTrue(last.exists)
            XCTAssertEqual(last.label, language == "en" ? "Furry puppet" : "毛茸茸布偶")
            screenshot(app, "gul447-icons-bottom-" + language)
            app.terminate()
        }
    }

    @MainActor
    func testAppIconChangeUsesSystemResult() {
        let app = XCUIApplication()
        app.launchArguments = ["--synthetic-preview", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.sidebar.open"].waitForExistence(timeout: 10))
        openHistory(app)
        app.buttons["chat.account"].tap()
        app.buttons["settings.appearance.dark"].tap()
        let entry = app.buttons["settings.appIcon"]
        if !entry.isHittable { app.swipeUp() }
        entry.tap()
        let primary = app.buttons["settings.appIcon.primary"]
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        let black = app.buttons["settings.appIcon.black"]
        let wasBlack = black.isSelected
        let target = wasBlack ? primary : black
        let wasPrimary = primary.isSelected
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let confirmation = springboard.alerts.firstMatch
        target.tap()
        let failure = app.alerts["Unable to change app icon"]
        let result = NSPredicate { _, _ in confirmation.exists || target.isSelected || failure.exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: result, object: nil)],
                                     timeout: 15), .completed)
        if failure.exists {
            screenshot(app, "gul447-native-change-failed")
            failure.buttons["OK"].tap()
            XCTAssertFalse(target.isSelected)
            XCTAssertEqual(primary.isSelected, wasPrimary)
        } else {
            // iOS can present a system-owned confirmation after applying the icon.
            if confirmation.exists {
                screenshot(springboard, "gul447-system-confirmation")
                confirmation.buttons.firstMatch.tap()
            }
            let applied = NSPredicate { _, _ in target.isSelected }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: applied, object: nil)],
                                         timeout: 5), .completed)
            XCTAssertTrue(target.isSelected)
            screenshot(app, "gul447-native-change-applied")
            app.terminate()
            app.launch()
            XCTAssertTrue(app.buttons["chat.sidebar.open"].waitForExistence(timeout: 10))
            openHistory(app)
            app.buttons["chat.account"].tap()
            if !entry.isHittable { app.swipeUp() }
            entry.tap()
            XCTAssertTrue(target.waitForExistence(timeout: 5))
            XCTAssertTrue(target.isSelected)
            // Restore the initial system icon after verifying persistence.
            let original = wasBlack ? black : primary
            original.tap()
            let restored = NSPredicate { _, _ in confirmation.exists || original.isSelected }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: restored, object: nil)],
                                         timeout: 15), .completed)
            if confirmation.exists { confirmation.buttons.firstMatch.tap() }
            let originalSelected = NSPredicate { _, _ in original.isSelected }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: originalSelected, object: nil)],
                                         timeout: 5), .completed)
            XCTAssertTrue(original.isSelected)
        }
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
        let more = app.buttons["chat.more.answer"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        if !more.isHittable {
            app.swipeUp()
        }
        more.tap()
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
        // Closing the sheet returns to the answer; the menu itself has closed.
        XCTAssertTrue(more.waitForExistence(timeout: 5))
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
    func testConnectionDismissalAndProviderLayout() {
        for language in ["en", "zh-Hans"] {
            let app = XCUIApplication()
            app.launchArguments = ["--synthetic-preview", "--synthetic-offline", "--synthetic-providers",
                                   "-AppleLanguages", "(\(language))"]
            app.launch()
            let close = app.buttons["connectivity.dismiss"]
            XCTAssertTrue(close.waitForExistence(timeout: 10))
            screenshot(app, "gul449-connection-" + language)
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 5))
            app.buttons["modelPicker"].tap()
            app.buttons["changeModel"].tap()
            let local = app.buttons["model-local-deepseek-chat"]
            XCTAssertTrue(local.waitForExistence(timeout: 5))
            local.tap()
            XCTAssertTrue(app.staticTexts[language == "en" ? "Not supported" : "不支持"]
                .waitForExistence(timeout: 5))
            screenshot(app, "gul449-local-model-" + language)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
            openHistory(app)
            XCTAssertFalse(app.descendants(matching: .any)["chat.sidebar"]
                .descendants(matching: .any)["connectivity.banner"].exists)
            app.buttons["chat.account"].tap()
            app.buttons["settings.providers"].tap()
            app.buttons["providers.item.preview-deepseek"].tap()
            let key = app.secureTextFields["provider.key"]
            XCTAssertTrue(key.waitForExistence(timeout: 5))
            let saved = app.staticTexts[language == "en"
                ? "Saved · enter a new key to replace it" : "已保存 · 输入新的 Key 可替换"]
            XCTAssertTrue(saved.exists)
            XCTAssertGreaterThanOrEqual(saved.frame.minY, key.frame.maxY)
            let enabled = app.switches["provider.model.deepseek-chat"]
            let vision = app.switches["provider.vision.deepseek-chat"]
            if !vision.isHittable { app.swipeUp() }
            XCTAssertTrue(enabled.exists)
            XCTAssertTrue(vision.exists)
            // Native Form accessibility frames include the complete adjoining rows.
            XCTAssertGreaterThanOrEqual(vision.frame.minY, enabled.frame.maxY)
            XCTAssertGreaterThanOrEqual(enabled.frame.height, 44)
            XCTAssertGreaterThanOrEqual(vision.frame.height, 44)
            screenshot(app, "gul449-provider-" + language)
            vision.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            let switched = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "1"), object: vision)
            XCTAssertEqual(XCTWaiter.wait(for: [switched], timeout: 5), .completed)
            XCTAssertEqual(enabled.value as? String, "1")
            app.terminate()
        }
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
