import XCTest

/// All flows use the in-memory fixture. No account or model request leaves the simulator.
final class ChatFlowTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testUnifiedModelEffortPickerAndModelCapabilities() {
        let app = launchPreview()
        app.buttons["chat.new"].tap()
        XCTAssertTrue(app.staticTexts["What's on your mind?"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "v3-new-conversation")
        app.buttons["modelPicker"].tap()
        XCTAssertTrue(app.staticTexts["reasoningTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reasoningTitle"].label, "Auto")
        XCTAssertFalse(app.buttons["resetReasoning"].isEnabled)
        pickHighestEffort(app)
        XCTAssertEqual(app.staticTexts["reasoningTitle"].label, "Ultra")
        attachScreenshot(app, name: "v3-reasoning")
        app.buttons["changeModel"].tap()
        XCTAssertTrue(app.buttons["model-fast-preview"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "v3-model-list")
        app.buttons["model-fast-preview"].tap()
        XCTAssertEqual(app.staticTexts["reasoningTitle"].label, "High")
        XCTAssertTrue(app.staticTexts["reasoningAdjustment"].exists)
        app.buttons["resetReasoning"].tap()
        XCTAssertEqual(app.staticTexts["reasoningTitle"].label, "Auto")
        app.buttons["changeModel"].tap()
        app.buttons["model-standard-preview"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["reasoningSlider"].exists)
        XCTAssertTrue(app.staticTexts["This model does not offer reasoning levels and answers in its own way."].exists)
        app.buttons["changeModel"].tap()
        app.buttons["model-preview"].tap()
        app.buttons["resetReasoning"].coordinate(withNormalizedOffset: CGVector(dx: -1, dy: -3)).tap()
        XCTAssertTrue(app.buttons["chat.send"].exists)
    }

    @MainActor
    func testReadConversationQuoteAndSendFollowUp() {
        let app = launchPreview()
        app.buttons["chat.history.preview"].tap()
        let quote = app.buttons["chat.quote.answer"]
        if !quote.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(quote.waitForExistence(timeout: 5))
        attachScreenshot(app, name: "v3-conversation")
        quote.tap()
        let composer = app.textFields["chat.composer"]
        XCTAssertTrue((composer.value as? String)?.contains("> Start with") == true)
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "This is a synthetic preview."))
            .firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Ask a follow-up")
    }

    @MainActor
    func testHistorySearchAndAccountValidation() {
        let app = launchPreview()
        attachScreenshot(app, name: "v3-history")
        let search = app.textFields["chat.search"]
        search.tap(); search.typeText("no-matching-title")
        XCTAssertFalse(app.buttons["chat.history.preview"].exists)
        app.buttons["Clear search"].tap()
        XCTAssertTrue(app.buttons["chat.history.preview"].exists)
        app.buttons["chat.history.Today"].tap()
        XCTAssertFalse(app.buttons["chat.history.preview"].exists)
        app.buttons["chat.history.Today"].tap()
        app.buttons["chat.account"].tap()
        app.buttons["Sign out"].tap()
        let submit = app.buttons["login.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertFalse(submit.isEnabled)
        attachScreenshot(app, name: "v3-login")
        app.textFields["login.email"].tap()
        app.textFields["login.email"].typeText("preview@example.invalid")
        app.secureTextFields["login.password"].tap()
        app.secureTextFields["login.password"].typeText("invalid")
        submit.tap()
        XCTAssertTrue(app.staticTexts["login.error"].waitForExistence(timeout: 5))
        app.secureTextFields["login.password"].tap()
        app.secureTextFields["login.password"].typeText("synthetic-password")
        submit.tap()
        XCTAssertTrue(app.buttons["chat.new"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.buttons["chat.new"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDesktopToolRunIsReadableAndCanBeStopped() {
        let app = launchPreview(arguments: ["--synthetic-tools"])
        app.buttons["chat.history.preview-tools"].tap()
        XCTAssertTrue(app.staticTexts["chat.run.status"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["chat.run.status"].label, "Waiting for the originating device")
        XCTAssertFalse(app.buttons["modelPicker"].isEnabled)
        attachScreenshot(app, name: "v3-desktop-tool")
        app.buttons["Stop response"].tap()
        XCTAssertTrue(app.staticTexts["chat.run.error"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["chat.run.error"].label, "Response stopped.")
        XCTAssertFalse(app.buttons["Stop response"].exists)
        XCTAssertEqual(app.staticTexts["chat.header.status"].label, "Stopped")
    }

    @MainActor
    func testChineseAndDarkDesignAndKeyboardChooser() {
        let app = launchPreview(arguments: ["--synthetic-dark"], language: "zh-Hans")
        app.buttons["chat.new"].tap()
        XCTAssertTrue(app.staticTexts["有什么想问的？"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "v3-zh-dark-empty")
        let composer = app.textFields["chat.composer"]
        composer.tap(); composer.typeText("Hello")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["modelPicker"].tap()
        XCTAssertTrue(app.buttons["changeModel"].waitForExistence(timeout: 5))
        app.buttons["changeModel"].tap()
        XCTAssertTrue(app.buttons["model-preview"].waitForExistence(timeout: 5))
        let model = app.buttons["model-preview"]
        XCTAssertTrue(model.isHittable)
        XCTAssertLessThan(model.frame.maxY, app.keyboards.firstMatch.frame.minY)
        attachScreenshot(app, name: "v3-zh-keyboard-models")
        app.buttons["model-fast-preview"].tap()
        pickHighestEffort(app)
        XCTAssertEqual(app.staticTexts["reasoningTitle"].label, "高")
        attachScreenshot(app, name: "v3-zh-dark-high")
    }

    @MainActor
    func testLandscapeKeyboardCanReachLastModel() {
        let app = launchPreview()
        app.buttons["chat.new"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let composer = app.textFields["chat.composer"]
        composer.tap(); composer.typeText("Hello")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["modelPicker"].tap()
        let changeModel = app.buttons["changeModel"]
        XCTAssertTrue(changeModel.waitForExistence(timeout: 5))
        changeModel.tap()
        let lastModel = app.buttons["model-standard-preview"]
        let list = app.scrollViews["modelCardScroll"]
        for _ in 0 ..< 5 {
            if lastModel.isHittable {
                break
            }
            list.swipeUp()
        }
        XCTAssertTrue(lastModel.isHittable)
        XCTAssertLessThan(lastModel.frame.maxY, app.keyboards.firstMatch.frame.minY)
        attachScreenshot(app, name: "v3-landscape-keyboard-last-model")
        lastModel.tap()
        XCTAssertEqual(app.staticTexts["reasoningTitle"].label, "Standard preview model")
    }

    @MainActor
    private func pickHighestEffort(_ app: XCUIApplication) {
        let slider = app.descendants(matching: .any).matching(identifier: "reasoningSlider").firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    }

    @MainActor
    private func launchPreview(arguments: [String] = [], language: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--synthetic-preview", "-AppleLanguages", "(\(language))", "-AppleLocale",
                               language == "en" ? "en_US" : "zh_CN"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["chat.new"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
