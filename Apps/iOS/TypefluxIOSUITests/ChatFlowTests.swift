import XCTest

/// All flows use the in-memory fixture. No account or model request leaves the simulator.
final class ChatFlowTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDrawerAndOutsideTapDismissKeyboardInChinese() {
        let app = launchPreview(language: "zh-Hans")
        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["chat.detail.new"].label, "新对话")
        composer.tap()
        composer.typeText("Draft stays here")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.scrollViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Draft stays here")
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.buttons["chat.sidebar.open"].tap()
        let sidebar = app.descendants(matching: .any)["chat.sidebar"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        XCTAssertEqual(sidebar.frame.minX, app.frame.minX, accuracy: 1)
        XCTAssertGreaterThan(sidebar.frame.height, app.frame.height * 0.8)
        XCTAssertEqual(app.buttons["chat.new"].label, "新对话")
        attachScreenshot(app, name: "gul209-zh-drawer")
        // The exposed strip belongs to the dismissing scrim, not the conversation.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.4)).tap()
        XCTAssertTrue(app.buttons["chat.detail.new"].waitForExistence(timeout: 5))
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["chat.detail.new"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        attachScreenshot(app, name: "gul209-zh-new-conversation")
        app.buttons["chat.sidebar.open"].tap()
        sidebar.swipeLeft()
        XCTAssertTrue(app.buttons["chat.detail.new"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testGoogleEntryReportsMissingConfigurationWithoutLeavingLogin() {
        let app = launchPreview(language: "zh-Hans")
        openHistory(app)
        app.buttons["chat.account"].tap()
        app.buttons["account.signOut"].tap()
        app.buttons.matching(identifier: "account.confirmSignOut").firstMatch.tap()
        let google = app.buttons["login.google"]
        XCTAssertTrue(google.waitForExistence(timeout: 5))
        XCTAssertEqual(google.label, "使用 Google 账号继续")
        attachScreenshot(app, name: "gul209-google-login")
        google.tap()
        XCTAssertTrue(app.staticTexts["login.error"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["login.error"].label, "Google 登录尚未配置。")
        XCTAssertTrue(google.isEnabled)
        XCTAssertTrue(app.buttons["login.email.open"].isEnabled)
    }

    @MainActor
    func testUnifiedModelEffortPickerAndModelCapabilities() {
        let app = launchPreview()
        XCTAssertTrue(app.staticTexts["What's on your mind?"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "v4-new-conversation")
        app.buttons["modelPicker"].tap()
        XCTAssertTrue(app.staticTexts["reasoningTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reasoningTitle"].label, "Auto")
        XCTAssertFalse(app.buttons["resetReasoning"].isEnabled)
        pickHighestEffort(app)
        XCTAssertEqual(app.staticTexts["reasoningTitle"].label, "Ultra")
        attachScreenshot(app, name: "v4-reasoning")
        app.buttons["changeModel"].tap()
        XCTAssertTrue(app.buttons["model-fast-preview"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "v4-model-list")
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
    func testRegenerateAnswerAndSendFollowUp() {
        let app = launchPreview()
        openHistory(app)
        attachScreenshot(app, name: "v4-sidebar")
        app.buttons["chat.history.preview"].tap()
        let regenerate = app.buttons["chat.regenerate.answer"]
        if regenerate.waitForExistence(timeout: 5), !regenerate.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["chat.copy.answer"].exists)
        XCTAssertTrue(app.buttons["chat.share.answer"].exists)
        attachScreenshot(app, name: "v4-conversation")
        regenerate.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "regenerated synthetic answer"))
            .firstMatch.waitForExistence(timeout: 5))
        let composer = app.textFields["chat.composer"]
        composer.tap(); composer.typeText("One more idea, please.")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "This is a synthetic preview."))
            .firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Ask a follow-up")
    }

    @MainActor
    func testHistorySearchAndAccountValidation() {
        let app = launchPreview()
        openHistory(app)
        let search = app.textFields["chat.search"]
        search.tap(); search.typeText("no-matching-title")
        XCTAssertFalse(app.buttons["chat.history.preview"].exists)
        app.buttons["chat.search.clear"].tap()
        XCTAssertTrue(app.buttons["chat.history.preview"].exists)
        app.buttons["chat.account"].tap()
        let signOut = app.buttons["account.signOut"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        signOut.tap()
        app.buttons.matching(identifier: "account.confirmSignOut").firstMatch.tap()
        let emailEntry = app.buttons["login.email.open"]
        XCTAssertTrue(emailEntry.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["login.apple"].exists)
        attachScreenshot(app, name: "v4-welcome")
        emailEntry.tap()
        let submit = app.buttons["login.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertFalse(submit.isEnabled)
        app.textFields["login.email"].tap()
        app.textFields["login.email"].typeText("preview@example.invalid")
        app.secureTextFields["login.password"].tap()
        app.secureTextFields["login.password"].typeText("invalid")
        attachScreenshot(app, name: "v4-email-login")
        submit.tap()
        XCTAssertTrue(app.staticTexts["login.error"].waitForExistence(timeout: 5))
        app.secureTextFields["login.password"].tap()
        app.secureTextFields["login.password"].typeText("synthetic-password")
        submit.tap()
        XCTAssertTrue(app.buttons["chat.sidebar.open"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.buttons["chat.sidebar.open"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDesktopToolRunIsReadableAndCanBeStopped() {
        let app = launchPreview(arguments: ["--synthetic-tools"])
        openHistory(app)
        app.buttons["chat.history.preview-tools"].tap()
        XCTAssertTrue(app.staticTexts["chat.run.status"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["chat.run.status"].label, "Waiting for the originating device")
        XCTAssertFalse(app.buttons["modelPicker"].isEnabled)
        attachScreenshot(app, name: "v4-desktop-tool")
        app.buttons["Stop response"].tap()
        XCTAssertTrue(app.staticTexts["chat.run.stopped"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["chat.run.stopped"].label, "Response stopped")
        XCTAssertFalse(app.staticTexts["chat.run.error"].exists)
        XCTAssertFalse(app.buttons["Stop response"].exists)
        XCTAssertEqual(app.staticTexts["chat.header.status"].label, "Stopped")
    }

    @MainActor
    func testChineseAndDarkDesignAndKeyboardChooser() {
        let app = launchPreview(arguments: ["--synthetic-dark"], language: "zh-Hans")
        XCTAssertTrue(app.staticTexts["有什么想问的？"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "v4-zh-dark-empty")
        let composer = app.textFields["chat.composer"]
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        composer.typeText("Hello")
        XCTAssertFalse(app.staticTexts["有什么想问的？"].exists)
        XCTAssertTrue(composer.isHittable)
        attachScreenshot(app, name: "qa-zh-keyboard-composer")
        app.buttons["modelPicker"].tap()
        XCTAssertTrue(app.buttons["changeModel"].waitForExistence(timeout: 5))
        app.buttons["changeModel"].tap()
        XCTAssertTrue(app.buttons["model-preview"].waitForExistence(timeout: 5))
        let model = app.buttons["model-preview"]
        XCTAssertTrue(model.isHittable)
        XCTAssertLessThan(model.frame.maxY, app.keyboards.firstMatch.frame.minY)
        attachScreenshot(app, name: "v4-zh-keyboard-models")
        app.buttons["model-fast-preview"].tap()
        pickHighestEffort(app)
        XCTAssertEqual(app.staticTexts["reasoningTitle"].label, "高")
        attachScreenshot(app, name: "v4-zh-dark-high")
    }

    @MainActor
    func testLandscapeKeyboardCanReachLastModel() async throws {
        let app = launchPreview()
        let landscapeWidth = app.windows.firstMatch.frame.height
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let window = app.windows.firstMatch
        for _ in 0 ..< 50 {
            if abs(window.frame.width - landscapeWidth) < 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(window.frame.width, window.frame.height)
        let composer = app.textFields["chat.composer"]
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        composer.typeText("Hello")
        XCTAssertFalse(app.staticTexts["What's on your mind?"].exists)
        XCTAssertTrue(composer.isHittable)
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
        attachScreenshot(app, name: "v4-landscape-keyboard-last-model")
        lastModel.tap()
        XCTAssertEqual(app.staticTexts["reasoningTitle"].label, "Kimi K2")
    }

    @MainActor
    private func pickHighestEffort(_ app: XCUIApplication) {
        let slider = app.descendants(matching: .any).matching(identifier: "reasoningSlider").firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    }

    @MainActor
    private func launchPreview(arguments: [String] = [], language: String = "en") -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--synthetic-preview", "-AppleLanguages", "(\(language))", "-AppleLocale",
                               language == "en" ? "en_US" : "zh_CN"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["chat.sidebar.open"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func openHistory(_ app: XCUIApplication) {
        app.buttons["chat.sidebar.open"].tap()
        XCTAssertTrue(app.buttons["chat.new"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        // Capture the display rather than the application's rotated window crop.
        // The image's logical size includes its orientation, unlike CGImage pixels.
        let screenshot = XCUIScreen.main.screenshot()
        let windowSize = app.windows.firstMatch.frame.size
        let imageSize = screenshot.image.size
        XCTAssertEqual(imageSize.width / imageSize.height,
                       windowSize.width / windowSize.height, accuracy: 0.01)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
